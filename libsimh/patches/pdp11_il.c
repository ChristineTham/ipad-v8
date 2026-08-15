/* pdp11_il.c: Interlan NI1010 Ethernet Communications Controller

   Written for the ipnx project (https://github.com/ChristineTham/ipad-v8) so
   that Research Unix 8th Edition can have real TCP/IP under SIMH.

   SIMH models exactly one VAX-780 Ethernet controller, the DEC DEUNA/DELUA
   (XU).  V8 has no DEUNA driver: dev/ contains an Interlan NI1010 driver and
   a 3Com one, and nothing else.  Rather than write a 1985-vintage streams
   network driver from scratch, this models the hardware V8 already knows.

   The conformance specification is V8's own driver, which is the thing that
   has to work:

     usr/sys/dev/ill.c    the driver conf/files actually builds for `il'
                          (dev/il.c is a second, unconfigured driver)
     usr/sys/h/ill_reg.h  registers, receive header, statistics record

   Behaviour that the driver pins down, and which is easy to get wrong:

   - Reading the CSR clears CDONE.  ill.c's ilprobe() says so in a comment
     against "i = addr->il_csr;" -- "clear CDONE" -- and ilattach() depends on
     it: it spins until CDONE, then reads the CSR again expecting the status
     field to have survived.  So a read clears CDONE and RDONE, never STATUS.

   - The board owns the source address.  ilfixheader() overwrites the source
     field with the destination and then skips six bytes, so what arrives at
     the controller is 6 bytes of destination, 2 bytes of type, then data --
     "the normal ethernet header with the source field removed".  The
     controller inserts its own address.

   - A received frame is DMA'd as a 4-byte prefix (status, pad, length) then
     the frame *including* its 4-byte CRC.  ilr_length counts the frame and
     the CRC but not the prefix: ilrint() computes the payload length as
     ilr_length - sizeof(struct il_rheader) and rejects anything outside
     [46, 1500], then re-derives the frame as ilr_length - 4.  We have no CRC
     from the host network, so four bytes are appended to keep the arithmetic
     honest.

   - Two vectors.  ilprobe() fires a command interrupt and then does
     `cvec -= 4', so the command vector is the base + 4 and the base itself is
     the receive vector.

   - Transmission is fragmented.  ill.c defines BOGUS, commented "CDONE
     doesn't work", and because of it hands the controller one buffer at a
     time: ILC_LDXMIT for each fragment and ILC_XMIT for the last.  So LDXMIT
     has to accumulate and only XMIT may put anything on the wire.
*/

#if defined (VM_VAX)                                    /* VAX version */
#include "vax_defs.h"
#else                                                   /* PDP-11 version */
#include "pdp11_defs.h"
#endif

#include "sim_ether.h"

extern int32 tmxr_poll;                                 /* calibrated poll interval */

/* Registers */

#define IL_CSR          0                               /* command and status */
#define IL_BAR          1                               /* buffer address */
#define IL_BCR          2                               /* byte count */

#define IOLN_IL         010                             /* 3 registers, 8b slot */

/* Command and status register */

#define ILCSR_EUA       0xC000                          /* extended UNIBUS address */
#define ILCSR_CMD       0x3F00                          /* command function code */
#define ILCSR_CDONE     0x0080                          /* command done */
#define ILCSR_CIE       0x0040                          /* command interrupt enable */
#define ILCSR_RDONE     0x0020                          /* receive DMA done */
#define ILCSR_RIE       0x0010                          /* receive interrupt enable */
#define ILCSR_STATUS    0x000F                          /* command status code */

/* Commands */

#define ILC_MLPBAK      0x0100                          /* module interface loopback */
#define ILC_ILPBAK      0x0200                          /* internal loopback */
#define ILC_CLPBAK      0x0300                          /* clear loopback */
#define ILC_PRMSC       0x0400                          /* set promiscuous */
#define ILC_CLPRMSC     0x0500                          /* clear promiscuous */
#define ILC_RCVERR      0x0600                          /* set receive-on-error */
#define ILC_CRCVERR     0x0700                          /* clear receive-on-error */
#define ILC_OFFLINE     0x0800                          /* go offline */
#define ILC_ONLINE      0x0900                          /* go online */
#define ILC_DIAG        0x0A00                          /* on-board diagnostics */
#define ILC_ISA         0x0D00                          /* set insert source address */
#define ILC_CISA        0x0E00                          /* clear insert source address */
#define ILC_DEFPA       0x0F00                          /* physical address to default */
#define ILC_ALLMC       0x1000                          /* receive all multicast */
#define ILC_CALLMC      0x1100                          /* clear receive all multicast */
#define ILC_STAT        0x1800                          /* report and reset statistics */
#define ILC_DELAYS      0x1900                          /* report collision delays */
#define ILC_RCV         0x2000                          /* supply receive buffer */
#define ILC_LDXMIT      0x2800                          /* load transmit data */
#define ILC_XMIT        0x2900                          /* load transmit data and send */
#define ILC_LDGRPS      0x2A00                          /* load group addresses */
#define ILC_RMGRPS      0x2B00                          /* delete group addresses */
#define ILC_LDPA        0x2C00                          /* load physical address */
#define ILC_FLUSH       0x3000                          /* flush receive queue */
#define ILC_RESET       0x3F00                          /* reset */

/* Status codes */

#define ILERR_SUCCESS   0
#define ILERR_RETRIES   1
#define ILERR_BADCMD    2
#define ILERR_INVCMD    3
#define ILERR_RECVERR   4
#define ILERR_BUFSIZ    5
#define ILERR_FRAMESIZ  6
#define ILERR_NXM       15

/* Frame status byte, at the head of every received frame */

#define ILFSTAT_C       0x1                             /* CRC error */
#define ILFSTAT_A       0x2                             /* alignment error */
#define ILFSTAT_L       0x4                             /* frames lost before this */

#define IL_HDRLEN       4                               /* status, pad, length */
#define IL_CRCLEN       4                               /* CRC the board would have kept */
#define IL_MAXFRAME     (14 + 1500 + IL_CRCLEN)
#define IL_STATLEN      66                              /* sizeof (struct il_stats) */
#define IL_RXQ          8                               /* supplied receive buffers */
#define IL_TXBUF        (IL_MAXFRAME + 64)

/* Debug flags */

#define DBG_REG         0x0001                          /* register access */
#define DBG_CMD         0x0002                          /* commands */
#define DBG_PKT         0x0004                          /* packet headers */
#define DBG_DAT         0x0008                          /* packet contents */
#define DBG_INT         0x0010                          /* interrupts */
#define DBG_ETH         0x0020                          /* sim_ether */

static DEBTAB il_debug[] = {
    { "REG", DBG_REG, "register access" },
    { "CMD", DBG_CMD, "controller commands" },
    { "PKT", DBG_PKT, "packet headers" },
    { "DAT", DBG_DAT, "packet contents" },
    { "INT", DBG_INT, "interrupts" },
    { "ETH", DBG_ETH, "ethernet layer" },
    { "TRACE", 0xFFFF, "everything" },
    { NULL, 0 }
    };

/* Controller state */

struct il_rxbuf {
    uint32              ba;                             /* UNIBUS address */
    uint32              bc;                             /* byte count */
    };

static struct il_ctx {
    uint16              csr;                            /* command and status */
    uint16              bar;                            /* buffer address */
    uint16              bcr;                            /* byte count */
    int                 cie;                            /* command interrupt armed */
    int                 rie;                            /* receive interrupt armed */
    int                 cint;                           /* command interrupt pending */
    int                 rint;                           /* receive interrupt pending */
    int                 online;
    int                 promisc;
    int                 loopback;                       /* internal loopback mode */
    int                 lost;                           /* frames dropped since last delivered */
    struct il_rxbuf     rxq[IL_RXQ];
    int                 rxq_head;
    int                 rxq_count;
    int                 rxburst;                /* fast-poll calls left */
    uint8               rxframe[IL_MAXFRAME + IL_HDRLEN];   /* frame in flight */
    uint32              rxtotal;                            /* bytes to hand over */
    uint32              rxoff;                              /* handed over so far */
    int                 rxbusy;                             /* mid-delivery */
    uint8               txbuf[IL_TXBUF];                /* accumulated by LDXMIT */
    uint32              txlen;
    ETH_MAC             mac;
    ETH_DEV            *eth;
    ETH_PACK            rxpkt;
    ETH_PACK            txpkt;
    uint32              ipackets, opackets, ierrors, oerrors;
    } il = { 0 };

/* Interlan boards shipped with a 02:07:01 prefix.  The low three bytes are
   arbitrary; SET IL MAC= overrides the lot. */
static ETH_MAC il_mac_default = { 0x02, 0x07, 0x01, 0x00, 0x00, 0x01 };
static char il_mac_string[20] = "02:07:01:00:00:01";

t_stat il_rd (int32 *data, int32 PA, int32 access);
t_stat il_wr (int32 data, int32 PA, int32 access);
t_stat il_svc (UNIT *uptr);
t_stat il_reset (DEVICE *dptr);
t_stat il_attach (UNIT *uptr, CONST char *cptr);
t_stat il_detach (UNIT *uptr);
t_stat il_set_mac (UNIT *uptr, int32 val, CONST char *cptr, void *desc);
t_stat il_show_mac (FILE *st, UNIT *uptr, int32 val, CONST void *desc);
t_stat il_show_stats (FILE *st, UNIT *uptr, int32 val, CONST void *desc);
t_stat il_help (FILE *st, DEVICE *dptr, UNIT *uptr, int32 flag, const char *cptr);
t_stat il_attach_help (FILE *st, DEVICE *dptr, UNIT *uptr, int32 flag, const char *cptr);
const char *il_description (DEVICE *dptr);
int32 il_rint_ack (void);
int32 il_cint_ack (void);
static void il_command (uint16 data);
static void il_deliver (const uint8 *frame, size_t len);
static void il_rxpump (void);
static void il_update_filter (void);

DIB il_dib = {
    IOBA_AUTO, IOLN_IL, &il_rd, &il_wr,
    2, IVCL (ILR), VEC_AUTO, { &il_rint_ack, &il_cint_ack },
    IOLN_IL,
    };

UNIT il_unit[1] = {
    { UDATA (&il_svc, UNIT_IDLE|UNIT_ATTABLE|UNIT_DISABLE, 0) }
    };

REG il_reg[] = {
    { GRDATAD (CSR,     il.csr,     DEV_RDX, 16, 0, "command and status register") },
    { GRDATAD (BAR,     il.bar,     DEV_RDX, 16, 0, "buffer address register") },
    { GRDATAD (BCR,     il.bcr,     DEV_RDX, 16, 0, "byte count register") },
    { FLDATAD (ONLINE,  il.online,  0,              "controller online") },
    { FLDATAD (PROMISC, il.promisc, 0,              "promiscuous mode") },
    { FLDATAD (LOOPBAK, il.loopback,0,              "internal loopback mode") },
    { FLDATAD (CINT,    il.cint,    0,              "command interrupt pending") },
    { FLDATAD (RINT,    il.rint,    0,              "receive interrupt pending") },
    { DRDATAD (RXQ,     il.rxq_count, 8,            "queued receive buffers") },
    { FLDATAD (RXBUSY,  il.rxbusy,  0,              "frame spanning buffers in flight") },
    { DRDATAD (RXTOTAL, il.rxtotal, 32,             "bytes in the frame in flight") },
    { DRDATAD (RXOFF,   il.rxoff,   32,             "bytes of it already delivered") },
    { BRDATAD (RXFRAME, il.rxframe, 16, 8, sizeof (il.rxframe), "frame in flight") },
    { DRDATAD (IPKTS,   il.ipackets, 32,            "packets received") },
    { DRDATAD (OPKTS,   il.opackets, 32,            "packets sent") },
    { DRDATAD (IERRS,   il.ierrors,  32,            "receive errors") },
    { DRDATAD (OERRS,   il.oerrors,  32,            "transmit errors") },
    { BRDATAD (MAC,     il.mac, 16, 8, sizeof (ETH_MAC), "physical address") },
    { GRDATA  (DEVADDR, il_dib.ba,  DEV_RDX, 32, 0), REG_HRO },
    { GRDATA  (DEVVEC,  il_dib.vec, DEV_RDX, 16, 0), REG_HRO },
    { NULL }
    };

MTAB il_mod[] = {
    { MTAB_XTD|MTAB_VDV|MTAB_VALR, 0, "MAC", "MAC=aa:bb:cc:dd:ee:ff",
        &il_set_mac, &il_show_mac, NULL, "MAC address" },
    { MTAB_XTD|MTAB_VDV|MTAB_NMO, 0, "STATISTICS", NULL,
        NULL, &il_show_stats, NULL, "Display statistics" },
    { MTAB_XTD|MTAB_VDV|MTAB_VALR, 010, "ADDRESS", "ADDRESS",
        &set_addr, &show_addr, NULL, "Bus address" },
    { MTAB_XTD|MTAB_VDV|MTAB_VALR, 0, "VECTOR", "VECTOR",
        &set_vec, &show_vec, NULL, "Interrupt vector" },
    { MTAB_XTD|MTAB_VDV, 0, NULL, "AUTOCONFIGURE",
        &set_addr_flt, NULL, NULL, "Enable autoconfiguration of address & vector" },
    { 0 }
    };

DEVICE il_dev = {
    "IL", il_unit, il_reg, il_mod,
    1, DEV_RDX, 8, 1, DEV_RDX, 8,
    NULL, NULL, &il_reset,
    NULL, &il_attach, &il_detach,
    &il_dib, DEV_DISABLE | DEV_DIS | DEV_UBUS | DEV_DEBUG | DEV_ETHER,
    0, il_debug, NULL, NULL, &il_help, &il_attach_help, NULL,
    &il_description
    };

/* The 18-bit UNIBUS address is split across two registers: the low 16 bits
   live in the BAR, and bits 17:16 ride in the top of the command word.  ill.c
   writes `((ubaddr >> 2) & IL_EUA)', which lands address bit 17 in CSR<15>
   and bit 16 in CSR<14>. */

static uint32 il_dmaddr (uint16 cmdword)
{
return (((uint32)(cmdword & ILCSR_EUA)) << 2) | (uint32)il.bar;
}

static void il_setcint (void)
{
il.csr |= ILCSR_CDONE;
if (il.cie) {
    il.cint = 1;
    SET_INT (ILC);
    sim_debug (DBG_INT, &il_dev, "command interrupt\n");
    }
}

static void il_setrint (void)
{
il.csr |= ILCSR_RDONE;
if (il.rie) {
    il.rint = 1;
    SET_INT (ILR);
    sim_debug (DBG_INT, &il_dev, "receive interrupt\n");
    }
}

int32 il_cint_ack (void)
{
if (il.cint) {
    il.cint = 0;
    CLR_INT (ILC);
    return il_dib.vec + 4;                              /* command vector is base+4 */
    }
return 0;
}

int32 il_rint_ack (void)
{
if (il.rint) {
    il.rint = 0;
    CLR_INT (ILR);
    return il_dib.vec;                                  /* receive vector is the base */
    }
return 0;
}

/* Register access */

t_stat il_rd (int32 *data, int32 PA, int32 access)
{
switch ((PA >> 1) & 03) {

    case IL_CSR:
        *data = il.csr;
        /* A read clears the two done bits and leaves the status field --
           ilattach() spins on CDONE and then reads the status back. */
        il.csr &= ~(ILCSR_CDONE | ILCSR_RDONE);
        break;

    case IL_BAR:
        *data = il.bar;
        break;

    case IL_BCR:
        *data = il.bcr;
        break;

    default:
        return SCPE_NXM;
        }

sim_debug (DBG_REG, &il_dev, "il_rd(PA=0%o, reg=%d) = 0x%04X\n",
           PA, (PA >> 1) & 03, *data);
return SCPE_OK;
}

t_stat il_wr (int32 data, int32 PA, int32 access)
{
switch ((PA >> 1) & 03) {

    case IL_CSR:
        il_command ((uint16)data);
        break;

    case IL_BAR:
        il.bar = (uint16)data;
        break;

    case IL_BCR:
        il.bcr = (uint16)data;
        break;

    default:
        return SCPE_NXM;
        }

sim_debug (DBG_REG, &il_dev, "il_wr(PA=0%o, reg=%d, data=0x%04X)\n",
           PA, (PA >> 1) & 03, (uint16)data);
return SCPE_OK;
}

/* Command execution.  Everything completes synchronously: the driver spins on
   CDONE with a 200,000-iteration bail-out, so there is nothing to gain from
   pretending a real board's latency, and a good deal to lose. */

static void il_command (uint16 cmdword)
{
uint16 cmd = cmdword & ILCSR_CMD;
uint32 ba = il_dmaddr (cmdword);
uint32 status = ILERR_SUCCESS;
uint8 stat[IL_STATLEN];
uint32 n;

il.cie = (cmdword & ILCSR_CIE) != 0;
il.rie = (cmdword & ILCSR_RIE) != 0;

sim_debug (DBG_CMD, &il_dev, "command 0x%04X (cmd=0x%04X ba=0%o bc=%d cie=%d rie=%d)\n",
           cmdword, cmd, ba, il.bcr, il.cie, il.rie);

switch (cmd) {

    case ILC_RESET:
        il.online = 0;
        il.promisc = 0;
        il.loopback = 0;
        il.rxq_head = il.rxq_count = il.rxburst = 0;
        il.txlen = 0;
        il.lost = 0;
        il.csr &= ~(ILCSR_CDONE | ILCSR_RDONE);
        il_update_filter ();
        break;

    case ILC_ONLINE:
        il.online = 1;
        break;

    case ILC_OFFLINE:
        il.online = 0;
        break;

    case ILC_DIAG:
        /* On-board diagnostics.  Nothing here can fail. */
        break;

    case ILC_STAT:
        /* ilattach() learns the controller's physical address from this and
           from nothing else, so the address field has to be right even though
           every counter may be zero. */
        memset (stat, 0, sizeof (stat));
        stat[2] = 62;                                   /* ils_length, little endian */
        stat[3] = 0;
        memcpy (&stat[4], il.mac, sizeof (ETH_MAC));    /* ils_addr */
        stat[10] = il.ipackets & 0xFF;                  /* ils_frames */
        stat[11] = (il.ipackets >> 8) & 0xFF;
        stat[14] = il.opackets & 0xFF;                  /* ils_xmit */
        stat[15] = (il.opackets >> 8) & 0xFF;
        memcpy (&stat[50], "NI1010  ", 8);              /* ils_module */
        memcpy (&stat[58], "SIMH    ", 8);              /* ils_firmware */
        n = (il.bcr && il.bcr < sizeof (stat)) ? il.bcr : sizeof (stat);
        if (Map_WriteB (ba, (int32)n, stat) != 0)
            status = ILERR_NXM;
        break;

    case ILC_RCV:
        /* Queue a buffer for the next frame.  ill.c keeps ILOUTSTANDING == 1
           of these in flight, so overflowing the ring means we have a bug. */
        if (il.rxq_count >= IL_RXQ) {
            sim_debug (DBG_CMD, &il_dev, "receive buffer queue overflow\n");
            status = ILERR_BUFSIZ;
            break;
            }
        n = (il.rxq_head + il.rxq_count) % IL_RXQ;
        il.rxq[n].ba = ba;
        il.rxq[n].bc = il.bcr;
        il.rxq_count++;
        /* ilrint() supplies the next buffer from inside the handler when a
           frame has more to come, so this is where chaining continues. */
        il_rxpump ();
        break;

    case ILC_FLUSH:
        il.rxq_head = il.rxq_count = 0;
        il.rxbusy = 0;
        break;

    case ILC_LDXMIT:
    case ILC_XMIT:
        if (il.txlen + il.bcr > sizeof (il.txbuf)) {
            status = ILERR_BUFSIZ;
            il.txlen = 0;
            break;
            }
        if (il.bcr) {
            if (Map_ReadB (ba, (int32)il.bcr, &il.txbuf[il.txlen]) != 0) {
                status = ILERR_NXM;
                il.txlen = 0;
                break;
                }
            il.txlen += il.bcr;
            }
        if (cmd == ILC_LDXMIT)                          /* fragment: hold it */
            break;
        /* The accumulated buffer is destination (6) + type (2) + data; the
           board supplies the source address itself. */
        if (il.txlen < 8) {
            status = ILERR_FRAMESIZ;
            il.txlen = 0;
            break;
            }
        memset (&il.txpkt, 0, sizeof (il.txpkt));
        memcpy (&il.txpkt.msg[0], &il.txbuf[0], 6);             /* destination */
        memcpy (&il.txpkt.msg[6], il.mac, sizeof (ETH_MAC));    /* source */
        memcpy (&il.txpkt.msg[12], &il.txbuf[6], il.txlen - 6); /* type + data */
        il.txpkt.len = il.txlen + 6;
        if (il.txpkt.len < 60)                          /* pad to minimum frame */
            il.txpkt.len = 60;
        sim_debug (DBG_PKT, &il_dev, "transmit %d bytes\n", il.txpkt.len);
        if (il.eth && DEBUG_PRI (il_dev, DBG_DAT))
            eth_packet_trace_ex (il.eth, il.txpkt.msg, il.txpkt.len, "il-write", 1, DBG_DAT);
        if (il.loopback)
            il_deliver (il.txpkt.msg, il.txpkt.len);
        else if (il.eth) {
            if (eth_write (il.eth, &il.txpkt, NULL) != SCPE_OK) {
                il.oerrors++;
                status = ILERR_RETRIES;
                }
            }
        il.opackets++;
        il.txlen = 0;
        break;

    case ILC_PRMSC:
        il.promisc = 1;
        il_update_filter ();
        break;

    case ILC_CLPRMSC:
        il.promisc = 0;
        il_update_filter ();
        break;

    case ILC_ILPBAK:
    case ILC_MLPBAK:
        il.loopback = 1;
        break;

    case ILC_CLPBAK:
        il.loopback = 0;
        break;

    case ILC_LDPA:
        if (Map_ReadB (ba, sizeof (ETH_MAC), il.mac) != 0)
            status = ILERR_NXM;
        else {
            eth_mac_fmt (il.mac, il_mac_string);
            il_update_filter ();
            }
        break;

    case ILC_DEFPA:
        memcpy (il.mac, il_mac_default, sizeof (ETH_MAC));
        eth_mac_fmt (il.mac, il_mac_string);
        il_update_filter ();
        break;

    case ILC_ALLMC:
    case ILC_CALLMC:
    case ILC_LDGRPS:
    case ILC_RMGRPS:
    case ILC_RCVERR:
    case ILC_CRCVERR:
    case ILC_ISA:
    case ILC_CISA:
    case ILC_DELAYS:
        /* Accepted and ignored.  V8 issues none of these; answering them
           successfully is cheaper than an error path nothing will read. */
        break;

    default:
        sim_debug (DBG_CMD, &il_dev, "unimplemented command 0x%04X\n", cmd);
        status = ILERR_BADCMD;
        break;
        }

/* Keep the enables and the address bits the driver wrote, replace the status,
   and raise CDONE. */
il.csr = (il.csr & (ILCSR_CDONE | ILCSR_RDONE)) |
         (cmdword & (ILCSR_EUA | ILCSR_CMD | ILCSR_CIE | ILCSR_RIE)) |
         (uint16)status;
il_setcint ();
}

/* Hand a frame to the guest.  The layout is fixed by ilrint():

     offset 0  frame status byte
     offset 1  pad
     offset 2  ilr_length, little endian -- frame length including CRC
     offset 4  destination, source, type, data
               CRC (four bytes we invent; the host network has stripped it)

   ilr_length excludes the four-byte prefix, and ilrint() reads exactly
   ilr_length + 4 bytes.  A frame longer than the supplied buffer is truncated
   rather than dropped: ilsetup() explicitly asks for truncation by shortening
   the last buffer, and the length field is what lets the driver notice. */

static void il_deliver (const uint8 *frame, size_t len)
{
uint8 buf[IL_MAXFRAME + IL_HDRLEN];
struct il_rxbuf *rb;
uint32 total, n;

if (len < 14)
    return;
if (len > IL_MAXFRAME - IL_CRCLEN)
    len = IL_MAXFRAME - IL_CRCLEN;

if (il.rxq_count == 0) {                                /* nowhere to put it */
    il.lost = 1;
    il.ierrors++;
    sim_debug (DBG_PKT, &il_dev, "receive with no buffer, frame dropped\n");
    return;
    }

total = (uint32)len + IL_CRCLEN;                        /* what ilr_length counts */
buf[0] = il.lost ? ILFSTAT_L : 0;
buf[1] = 0;
buf[2] = total & 0xFF;
buf[3] = (total >> 8) & 0xFF;
memcpy (&buf[IL_HDRLEN], frame, len);
memset (&buf[IL_HDRLEN + len], 0, IL_CRCLEN);           /* stand-in CRC */
il.lost = 0;

if (il.eth && DEBUG_PRI (il_dev, DBG_DAT))
    eth_packet_trace_ex (il.eth, frame, (int)len, "il-read", 1, DBG_DAT);

memcpy (il.rxframe, buf, total + IL_HDRLEN);
il.rxtotal = total + IL_HDRLEN;
il.rxoff = 0;
il.rxbusy = 1;
il_rxpump ();
}

/* Hand over as much of the frame in flight as the buffer at the head of the
   queue will take, and interrupt.  ONE buffer per call, which is not a
   simplification but the contract.

   ill.c expects the controller to CHAIN a frame across as many receive
   buffers as it needs, one interrupt per buffer.  ilrint() reads ilr_length
   out of the first buffer, then subtracts each buffer's *programmed byte
   count* as the interrupts arrive, and only passes the packet upward once the
   remainder reaches zero:

        is->len -= (bp->wptr - bp->rptr);
        if(is->len <= 0) goto done;
        if((bp->wptr - bp->rptr) % 8) goto done;   // not chaining
        if(is->nbp == 0) ilsetup(is, addr, is->len);
        return;                                    // wait for the next one

   ILOUTSTANDING is 1, so the driver supplies the next buffer from inside that
   same handler -- which is why filling one buffer and interrupting, then
   waiting for ILC_RCV, is exactly what the hardware did.

   GETTING THIS WRONG DOES NOT LOOK LIKE A TRUNCATED PACKET.  A frame needing
   two buffers that gets one leaves ilrint() with is->len > 0, waiting on an
   interrupt that never comes: the receive path stops dead, and every read on
   that connection times out with nothing to show for it.  allocb() caps a
   block at rbsize[3] = 1024, so any frame over ~1024 bytes needs two buffers
   -- and nothing this project sent before netfs was ever that big.  It
   survived N2, N3 and most of N6 on 42-byte ARP and 130-byte DNS replies. */

static void il_rxpump (void)
{
struct il_rxbuf *rb;
uint32 chunk;

if (!il.rxbusy || il.rxq_count == 0)
    return;

rb = &il.rxq[il.rxq_head];
chunk = il.rxtotal - il.rxoff;
if (chunk > rb->bc)
    chunk = rb->bc;

if (Map_WriteB (rb->ba, (int32)chunk, &il.rxframe[il.rxoff]) != 0) {
    il.ierrors++;
    il.csr = (il.csr & ~ILCSR_STATUS) | ILERR_NXM;
    il.rxbusy = 0;
    }
else {
    il.rxoff += chunk;
    /* A byte count that is not a multiple of 8 is ilsetup()'s way of saying
       "last buffer, truncate here" -- it shortens the final buffer by 2 when
       the frame is larger than ETHERMTU. */
    if ((il.rxoff >= il.rxtotal) || ((rb->bc % 8) != 0)) {
        il.rxbusy = 0;
        il.ipackets++;
        }
    }

sim_debug (DBG_PKT, &il_dev, "receive %u bytes into 0%o (buffer %u, %u of %u)%s\n",
           chunk, rb->ba, rb->bc, il.rxoff, il.rxtotal,
           il.rxbusy ? ", more to come" : "");

il.rxq_head = (il.rxq_head + 1) % IL_RXQ;
il.rxq_count--;
il_setrint ();
}

/* Receive polling */

/* How long to keep polling fast after a packet, in service calls.  netfs is
   strictly request/response, so a frame arriving is very good evidence that
   another is about to. */
#define IL_BURST        200

t_stat il_svc (UNIT *uptr)
{
int count, got = 0;

if (il.eth) {
    il_rxpump ();                                       /* finish any chain */
    do {
        count = il.rxpkt.len = 0;
        if (il.rxbusy)                                  /* one frame at a time */
            break;
        eth_read (il.eth, &il.rxpkt, NULL);
        if (il.rxpkt.len > 0) {
            count = got = 1;
            il_deliver (il.rxpkt.msg, il.rxpkt.len);
            }
        } while (count && il.rxq_count && !il.rxbusy);
    }

/* THE LATENCY THIS AVOIDS IS THE WHOLE COST OF netfs.  The protocol costs one
   round trip per PATH COMPONENT -- nanami() in sys/neta.c walks a name a piece
   at a time -- so opening one file is several exchanges, and each used to wait
   for the next calibrated clock poll to notice the reply had arrived.
   tmxr_poll rides the 10 ms system clock, which is why this measured ~16 ms a
   request and ~30 files a minute regardless of file size.  It is a LATENCY
   bound and not a bandwidth one; counting bytes tells you nothing.

   So after a frame, poll hard for a bounded window, then go back to riding the
   clock.  The fallback is what keeps the machine idle-friendly: sim_idle()
   sleeps only when the unit at the head of the event queue has UNIT_IDLE --
   this one does -- but a unit that reschedules itself every few hundred
   microseconds FOREVER would keep the queue busy and pin a core anyway.  The
   window is bounded for exactly that reason: a quiet machine is back on the
   clock within IL_BURST calls and costs what it always did. */
/* RE-ARM ONLY WHEN THE LAST WINDOW HAS FULLY EXPIRED.  `if (got)' was wrong
   and the comment above was wrong with it: any packet reset the counter to
   full, so under steady traffic -- which SLiRP produces merely by existing --
   the window never closed and the unit rescheduled itself every 1000
   instructions forever.  UNIT_IDLE does not save you there: sim_idle() will
   not sleep across a sub-millisecond gap, so it spins instead.  Measured in
   the app: 99.5% of a core at an idle login: with networking on, against
   8.7-20% with it off, and a guest so starved that `date' took 30 s.  That is
   the stock unpatched figure -- the idle work of A1 undone by an optimisation
   that claimed to be bounded and was not.

   Expiring first means a burst is followed by at least one clock-paced poll,
   so the duty cycle is bounded no matter how much traffic arrives, while a
   request/response exchange still completes inside one window. */
if (got && il.rxburst == 0)
    il.rxburst = IL_BURST;
if (il.rxburst > 0) {
    il.rxburst--;
    sim_activate (uptr, 1000);                          /* ~200 us at 5 MHz */
    }
else
    sim_clock_coschedule (uptr, tmxr_poll);
return SCPE_OK;
}

static void il_update_filter (void)
{
ETH_MAC filter[2];

if (il.eth == NULL)
    return;
memcpy (filter[0], il.mac, sizeof (ETH_MAC));
memcpy (filter[1], eth_mac_bcast, sizeof (ETH_MAC));
eth_filter (il.eth, 2, filter, 0, il.promisc ? 1 : 0);
}

/* Reset, attach, detach */

t_stat il_reset (DEVICE *dptr)
{
il.csr = il.bar = il.bcr = 0;
il.cie = il.rie = il.cint = il.rint = 0;
il.online = il.promisc = il.loopback = il.lost = 0;
il.rxq_head = il.rxq_count = 0;
il.txlen = 0;
CLR_INT (ILC);
CLR_INT (ILR);
if (il.mac[0] == 0 && il.mac[1] == 0 && il.mac[2] == 0 &&
    il.mac[3] == 0 && il.mac[4] == 0 && il.mac[5] == 0) {
    memcpy (il.mac, il_mac_default, sizeof (ETH_MAC));
    eth_mac_fmt (il.mac, il_mac_string);
    }
il_update_filter ();
if (dptr->flags & DEV_DIS)
    sim_cancel (il_unit);
else if (il_unit[0].flags & UNIT_ATT)
    sim_clock_coschedule (il_unit, tmxr_poll);
return auto_config (dptr->name, (dptr->flags & DEV_DIS) ? 0 : 1);
}

t_stat il_attach (UNIT *uptr, CONST char *cptr)
{
char *tptr;
t_stat r;

tptr = (char *)malloc (strlen (cptr) + 1);
if (tptr == NULL)
    return SCPE_MEM;
strcpy (tptr, cptr);

il.eth = (ETH_DEV *)malloc (sizeof (ETH_DEV));
if (il.eth == NULL) {
    free (tptr);
    return SCPE_MEM;
    }
memset (il.eth, 0, sizeof (ETH_DEV));

r = eth_open (il.eth, cptr, &il_dev, DBG_ETH);
if (r != SCPE_OK) {
    free (tptr);
    free (il.eth);
    il.eth = NULL;
    return r;
    }
uptr->filename = tptr;
uptr->flags |= UNIT_ATT;
/* The NI1010 hands the CRC to the host, so ask sim_ether to keep one. */
eth_setcrc (il.eth, 1);
il_update_filter ();
sim_clock_coschedule (uptr, tmxr_poll);
return SCPE_OK;
}

t_stat il_detach (UNIT *uptr)
{
if (uptr->flags & UNIT_ATT) {
    sim_cancel (uptr);
    eth_close (il.eth);
    free (il.eth);
    il.eth = NULL;
    free (uptr->filename);
    uptr->filename = NULL;
    uptr->flags &= ~UNIT_ATT;
    }
return SCPE_OK;
}

/* SET/SHOW */

t_stat il_set_mac (UNIT *uptr, int32 val, CONST char *cptr, void *desc)
{
t_stat status;

if ((cptr == NULL) || (*cptr == 0))
    return SCPE_ARG;
status = eth_mac_scan_ex (il.mac, cptr, uptr);
if (status != SCPE_OK)
    return status;
eth_mac_fmt (il.mac, il_mac_string);
il_update_filter ();
return SCPE_OK;
}

t_stat il_show_mac (FILE *st, UNIT *uptr, int32 val, CONST void *desc)
{
char buffer[20];

eth_mac_fmt (il.mac, buffer);
fprintf (st, "MAC=%s", buffer);
return SCPE_OK;
}

t_stat il_show_stats (FILE *st, UNIT *uptr, int32 val, CONST void *desc)
{
fprintf (st, "NI1010 statistics:\n");
fprintf (st, "  packets received: %u\n", il.ipackets);
fprintf (st, "  packets sent:     %u\n", il.opackets);
fprintf (st, "  receive errors:   %u\n", il.ierrors);
fprintf (st, "  transmit errors:  %u\n", il.oerrors);
fprintf (st, "  queued rx bufs:   %d\n", il.rxq_count);
fprintf (st, "  state:            %s%s%s\n",
         il.online ? "online" : "offline",
         il.promisc ? ", promiscuous" : "",
         il.loopback ? ", loopback" : "");
if (il.eth)
    eth_show_dev (st, il.eth);
return SCPE_OK;
}

t_stat il_attach_help (FILE *st, DEVICE *dptr, UNIT *uptr, int32 flag, const char *cptr)
{
fprintf (st, "IL Ethernet interface\n\n");
fprintf (st, "  sim> ATTACH IL nat:\n\n");
fprintf (st, "The integrated NAT (SLiRP) support needs no host configuration and no\n");
fprintf (st, "privileges, so it is the usual choice.  ATTACH IL <host-device> uses a\n");
fprintf (st, "real interface instead; SHOW ETHERNET lists what is available.\n\n");
return SCPE_OK;
}

t_stat il_help (FILE *st, DEVICE *dptr, UNIT *uptr, int32 flag, const char *cptr)
{
fprintf (st, "Interlan NI1010 Ethernet Communications Controller (IL)\n\n");
fprintf (st, "The IL is a UNIBUS Ethernet controller with three registers -- command\n");
fprintf (st, "and status, buffer address, and byte count -- and a DMA engine driven by\n");
fprintf (st, "single commands rather than descriptor rings.  It is modelled here\n");
fprintf (st, "because Research Unix 8th Edition ships an NI1010 driver and no DEUNA\n");
fprintf (st, "driver, so the DEUNA (XU) that SIMH already provides is of no use to it.\n\n");
fprintf (st, "The controller inserts its own source address into every frame, which is\n");
fprintf (st, "why the driver hands it a header with the source field removed.\n\n");
fprint_set_help (st, dptr);
fprint_show_help (st, dptr);
fprint_reg_help (st, dptr);
return SCPE_OK;
}

const char *il_description (DEVICE *dptr)
{
return "IL: Interlan NI1010 Ethernet controller";
}

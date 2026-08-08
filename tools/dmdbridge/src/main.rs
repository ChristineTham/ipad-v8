//! Headless DMD 5620 bridge.
//!
//! Connects Seth Morabito's dmd_core (WE32100 DMD 5620 emulator) to SIMH's
//! DZ11 telnet listener, auto-logs-in to Research Unix V8, starts mux, and
//! dumps the 800x1024 framebuffer to PNG files as visual proof. This is a
//! desktop prototype of exactly the embedding the iPad app performs.

use dmd_core::Dmd;
use std::collections::VecDeque;
use std::fs;
use std::io::{ErrorKind, Read, Write};
use std::net::TcpStream;
use std::time::{Duration, Instant};

const FB_W: usize = 800;
const FB_H: usize = 1024;
const FB_BYTES: usize = FB_W * FB_H / 8;

const IAC: u8 = 255;
const DONT: u8 = 254;
const DO: u8 = 253;
const WONT: u8 = 252;
const WILL: u8 = 251;

/// Stateful telnet-IAC parser for the SIMH-to-us direction.
struct Telnet {
    state: u8, // 0 = data, 1 = saw IAC, 2 = saw IAC+verb (verb stored)
    verb: u8,
}

impl Telnet {
    fn new() -> Self {
        Telnet { state: 0, verb: 0 }
    }
    fn push(&mut self, b: u8, out: &mut VecDeque<u16>, reply: &mut Vec<u8>) {
        match self.state {
            0 => {
                if b == IAC {
                    self.state = 1;
                } else {
                    out.push_back(b as u16);
                }
            }
            1 => match b {
                IAC => {
                    out.push_back(IAC as u16);
                    self.state = 0;
                }
                243 => {
                    // Telnet BREAK command: deliver as an in-order break marker.
                    out.push_back(256);
                    self.state = 0;
                }
                DO | DONT | WILL | WONT => {
                    self.verb = b;
                    self.state = 2;
                }
                _ => self.state = 0,
            },
            _ => {
                match self.verb {
                    DO => reply.extend_from_slice(&[IAC, WONT, b]),
                    WILL => reply.extend_from_slice(&[IAC, DONT, b]),
                    _ => {}
                }
                self.state = 0;
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Phase {
    WaitLogin,
    WaitShell,
    MuxRunning,
    Gestures,
    Done,
}

enum Act {
    Move(u16, u16),
    Down(u8),
    Up(u8),
    Shot(&'static str),
    Type(&'static str),
}

fn dump_png(dir: &str, n: u32, label: &str, secs: f64, fb: &[u8]) {
    let path = format!("{dir}/shot_{n:02}_{label}_t{secs:.1}.png");
    let file = match fs::File::create(&path) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("png create failed: {e}");
            return;
        }
    };
    let mut enc = png::Encoder::new(file, FB_W as u32, FB_H as u32);
    enc.set_color(png::ColorType::Grayscale);
    enc.set_depth(png::BitDepth::Eight);
    let mut writer = enc.write_header().expect("png header");
    let mut pixels = Vec::with_capacity(FB_W * FB_H);
    for row in 0..FB_H {
        for col in 0..FB_W / 8 {
            let byte = fb[row * (FB_W / 8) + col];
            for bit in 0..8 {
                // 1-bit = lit phosphor -> white on black
                pixels.push(if byte & (0x80 >> bit) != 0 { 255 } else { 0 });
            }
        }
    }
    writer.write_image_data(&pixels).expect("png data");
    println!("[{secs:7.2}s] wrote {path}");
}

fn fb_hash(fb: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for &b in fb {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

fn main() {
    let shots_dir = std::env::args().nth(1).unwrap_or_else(|| "shots".into());
    fs::create_dir_all(&shots_dir).expect("mkdir shots");

    // Connect (retry: SIMH may still be booting).
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut sock = loop {
        match TcpStream::connect("127.0.0.1:8888") {
            Ok(s) => break s,
            Err(e) => {
                if Instant::now() > deadline {
                    panic!("could not connect to SIMH DZ: {e}");
                }
                std::thread::sleep(Duration::from_secs(2));
            }
        }
    };
    sock.set_nonblocking(true).unwrap();
    sock.set_nodelay(true).ok();
    println!("connected to SIMH DZ on 127.0.0.1:8888");

    let mut dmd = Dmd::new();
    dmd.reset(1).expect("dmd reset"); // firmware version 1 = 8;7;3 (required for V8 mux)
    println!("dmd_core reset; video_ram len = {}", dmd.video_ram().len());

    let t0 = Instant::now();
    let secs = |t: Instant| t.duration_since(t0).as_secs_f64();

    let mut telnet = Telnet::new();
    let mut rxq: VecDeque<u16> = VecDeque::new(); // host -> terminal, paced (256 = BREAK)
    let mut txbuf: Vec<u8> = Vec::new(); // terminal -> host, IAC-escaped
    let mut scan: Vec<u8> = Vec::new(); // parity-stripped host stream for prompts
    let mut kbq: VecDeque<u8> = VecDeque::new(); // pending keystrokes
    let mut phase = Phase::WaitLogin;
    let mut phase_since = Instant::now();

    // Metrics.
    let mut host_bytes_total: u64 = 0;
    let mut mux_t: Option<Instant> = None;
    let mut burst_bytes: u64 = 0;
    let mut last_rx_at = Instant::now();
    let mut download_done_at: Option<Instant> = None;

    // Framebuffer snapshots.
    let mut fbbuf = vec![0u8; FB_BYTES];
    let mut last_hash: u64 = 0;
    let mut last_shot = Instant::now() - Duration::from_secs(10);
    let mut last_fb_check = Instant::now();
    let mut shot_n: u32 = 0;

    // Mouse gesture script: open the button-3 menu, select an item, then
    // sweep a rectangle with button 3 (the classic "New layer" flow).
    // menuhit() pops the menu with the previously-selected item (initially
    // item 0 = "New") centered under the cursor, so releasing in place picks
    // New. The sweep that follows also uses button 3 (mux convention).
    let gestures: Vec<(u64, Act)> = vec![
        (0, Act::Move(400, 524)),
        (300, Act::Down(2)),
        (1200, Act::Shot("menu")),
        (1500, Act::Up(2)),
        (2300, Act::Shot("aftermenu")),
        (2700, Act::Move(180, 764)),
        (3000, Act::Down(2)),
        (3400, Act::Move(340, 594)),
        (3800, Act::Move(500, 414)),
        (4200, Act::Move(620, 204)),
        (4600, Act::Up(2)),
        (8000, Act::Shot("layer")),
        (8300, Act::Type("date\r")),
        (11500, Act::Type("cat /etc/motd\r")),
        (16000, Act::Shot("layer2")),
    ];
    let mut gest_i = 0usize;
    let mut gest_t0: Option<Instant> = None;
    // Mouse model: screen position the cursor is at, and the raw counter
    // values last injected (see Act::Move handling).
    let (mut cur_sx, mut cur_sy) = (0i32, 0i32);
    let (mut ctr_x, mut ctr_y) = (0u16, 0u16);

    let mut iter: u64 = 0;
    let mut kb_gap: u64 = 0;
    let hard_stop = t0 + Duration::from_secs(1500);
    let mut done_at: Option<Instant> = None;
    let mut last_progress = Instant::now();
    let mut stall_reported = false;
    let mut tx_ring: VecDeque<u8> = VecDeque::new();
    let mut rx_ring: VecDeque<u8> = VecDeque::new(); // raw host->terminal bytes (scan strips bit 7)
    let mut tx_since_mux: u64 = 0;
    // muxterm's COFF header: tsize 47820 + dsize 2504 = 50324 loadable bytes,
    // entry 0x71e85c. The 144,603-byte file size includes the symbol table,
    // which 32ld never downloads — the wire burst is ~55K (payload + packet
    // overhead + shell echo), NOT 144K. Session 6 finding.
    const MUXTERM_TEXTDATA: u64 = 50_324;
    const BURST_ESTIMATE: u64 = 55_000; // typical total burst incl. overhead

    // Pace the emulated CPU to ~10 MHz of wall time. The DUART is a
    // wall-clock state machine (like real hardware); a flat-out CPU races
    // its service deadlines and wedges the firmware's serial handshakes.
    let pace_start = Instant::now();
    let mut steps_total: u64 = 0;
    loop {
        dmd.run(500);
        steps_total += 500;
        iter += 1;
        if iter % 100 == 0 {
            let virt = steps_total as f64 / 10_000_000.0;
            let real = pace_start.elapsed().as_secs_f64();
            if virt > real + 0.002 {
                std::thread::sleep(Duration::from_micros(((virt - real) * 1e6) as u64));
            }
        }

        // Paced host->terminal injection: one byte per ~1000 emulated steps.
        if iter % 2 == 0 {
            if let Some(v) = rxq.pop_front() {
                if v == 256 {
                    println!("[{:7.2}s] BREAK delivered to terminal", secs(Instant::now()));
                    dmd.rs232_break();
                } else {
                    let b = v as u8;
                    dmd.rs232_rx(b);
                    scan.push(b & 0x7f);
                    if mux_t.is_some() {
                        rx_ring.push_back(b);
                        if rx_ring.len() > 96 {
                            rx_ring.pop_front();
                        }
                    }
                }
                if scan.len() > 8192 {
                    scan.drain(..4096);
                }
            }
        }

        // Terminal -> host (escape IAC for telnet).
        while let Some(b) = dmd.rs232_tx() {
            txbuf.push(b);
            if b == IAC {
                txbuf.push(IAC);
            }
            if mux_t.is_some() {
                tx_since_mux += 1;
                tx_ring.push_back(b);
                if tx_ring.len() > 64 {
                    tx_ring.pop_front();
                }
            }
        }
        while dmd.keyboard_tx().is_some() {} // drain keyboard-channel beeps
        if dmd.rs232_tx_break() {
            txbuf.push(IAC);
            txbuf.push(243); // telnet BREAK command
            println!("[{:7.2}s] terminal BREAK -> telnet IAC BRK", secs(Instant::now()));
        }

        // Keyboard typing, spaced out.
        if kb_gap > 0 {
            kb_gap -= 1;
        } else if let Some(k) = kbq.pop_front() {
            dmd.keyboard_rx(k);
            kb_gap = 2000; // ~100ms/key at paced 10MHz: kb FIFO is 3-deep and wall-clock paced
        }

        // Socket I/O.
        if iter % 64 == 0 {
            let mut buf = [0u8; 4096];
            match sock.read(&mut buf) {
                Ok(0) => {
                    println!("[{:7.2}s] SIMH closed the connection", secs(Instant::now()));
                    break;
                }
                Ok(n) => {
                    let mut reply = Vec::new();
                    for &b in &buf[..n] {
                        telnet.push(b, &mut rxq, &mut reply);
                    }
                    if !reply.is_empty() {
                        let _ = sock.write_all(&reply);
                    }
                    host_bytes_total += n as u64;
                    if mux_t.is_some() && download_done_at.is_none() {
                        burst_bytes += n as u64;
                    }
                    last_rx_at = Instant::now();
                }
                Err(ref e) if e.kind() == ErrorKind::WouldBlock => {}
                Err(e) => {
                    println!("socket error: {e}");
                    break;
                }
            }
            if !txbuf.is_empty() {
                match sock.write(&txbuf) {
                    Ok(n) => {
                        txbuf.drain(..n);
                    }
                    Err(ref e) if e.kind() == ErrorKind::WouldBlock => {}
                    Err(e) => {
                        println!("socket write error: {e}");
                        break;
                    }
                }
            }
        }

        // Prompt-driven phase machine.
        let has = |scan: &Vec<u8>, pat: &[u8]| {
            scan.windows(pat.len()).rev().take(2048).any(|w| w == pat)
        };
        match phase {
            Phase::WaitLogin => {
                if has(&scan, b"login:") {
                    println!("[{:7.2}s] login prompt seen; typing root", secs(Instant::now()));
                    kbq.extend(b"root\r");
                    scan.clear();
                    phase = Phase::WaitShell;
                    phase_since = Instant::now();
                }
            }
            Phase::WaitShell => {
                if Instant::now().duration_since(phase_since) > Duration::from_secs(25) {
                    println!(
                        "[{:7.2}s] shell never appeared; retrying login (keystroke loss)",
                        secs(Instant::now())
                    );
                    kbq.clear();
                    kbq.extend(b"\r");
                    scan.clear();
                    phase = Phase::WaitLogin;
                    phase_since = Instant::now();
                } else if has(&scan, b"# ") {
                    println!("[{:7.2}s] shell prompt; starting mux", secs(Instant::now()));
                    kbq.extend(b"cd /tmp; /usr/jerq/bin/mux 2>muxerr\r");
                    scan.clear();
                    mux_t = Some(Instant::now());
                    phase = Phase::MuxRunning;
                    phase_since = Instant::now();
                }
            }
            Phase::MuxRunning => {
                // Download complete when we've seen most of muxterm AND the
                // burst has gone properly quiet (block-ack stalls are shorter).
                if let Some(mt) = mux_t {
                    let now = Instant::now();
                    if now.duration_since(last_progress) > Duration::from_secs(30) {
                        last_progress = now;
                        let el = now.duration_since(mt).as_secs_f64();
                        let rate = burst_bytes as f64 / el.max(0.001);
                        let eta = (BURST_ESTIMATE.saturating_sub(burst_bytes)) as f64 / rate.max(1.0);
                        println!(
                            "[{:7.2}s] download progress: {} bytes ({:.0}% of muxterm), {:.0} B/s, ~{:.0}s to go",
                            secs(now),
                            burst_bytes,
                            (100.0 * burst_bytes as f64 / BURST_ESTIMATE as f64).min(100.0),
                            rate,
                            eta
                        );
                    }
                    if now.duration_since(last_rx_at) > Duration::from_secs(15)
                        && !stall_reported
                    {
                        stall_reported = true;
                        let mut pcs = Vec::new();
                        for _ in 0..8 {
                            dmd.run(2000);
                            pcs.push(dmd.get_pc());
                        }
                        let tail: Vec<u8> = scan.iter().rev().take(160).rev().cloned().collect();
                        println!("[{:7.2}s] STALL duart: {}", secs(now), dmd.duart_debug());
                        let txv: Vec<u8> = tx_ring.iter().cloned().collect();
                        println!("[{:7.2}s] STALL tx_since_mux={} last tx bytes: {:02x?}",
                            secs(now), tx_since_mux, txv);
                        // Extract printable ASCII runs from the whole scan buffer:
                        // a dying mux/32ld error message hides among binary.
                        let mut runs: Vec<String> = Vec::new();
                        let mut cur = String::new();
                        for &b in scan.iter() {
                            if (0x20..0x7f).contains(&b) {
                                cur.push(b as char);
                            } else {
                                if cur.len() >= 5 { runs.push(cur.clone()); }
                                cur.clear();
                            }
                        }
                        if cur.len() >= 5 { runs.push(cur); }
                        let n = runs.len();
                        println!("[{:7.2}s] STALL ascii runs (last 12 of {}): {:?}",
                            secs(now), n, &runs[n.saturating_sub(12)..]);
                        println!(
                            "[{:7.2}s] STALL: {} bytes, no rx 15s. pc: {:x?} kbq={} txbuf={} scan tail: {:?}",
                            secs(now), burst_bytes, pcs, kbq.len(), txbuf.len(),
                            String::from_utf8_lossy(&tail)
                        );
                        // Raw host->terminal bytes: what did the host last send us?
                        let rxv: Vec<u8> = rx_ring.iter().cloned().collect();
                        println!("[{:7.2}s] STALL last raw rx bytes ({}): {:02x?}",
                            secs(now), rxv.len(), rxv);
                        // Dump the code around the spin loop so it can be
                        // disassembled offline (range follows the sampled PCs).
                        let lo = (*pcs.iter().min().unwrap() as usize & !3).saturating_sub(0x40);
                        let hi = (*pcs.iter().max().unwrap() as usize & !3) + 0x44;
                        let mut words = Vec::new();
                        let mut a = lo;
                        while a < hi {
                            words.push(match dmd.read_word(a) {
                                Some(w) => format!("{:08x}", w),
                                None => "????????".into(),
                            });
                            a += 4;
                        }
                        println!("[{:7.2}s] STALL code dump {:06x}..{:06x}: {}",
                            secs(now), lo, hi, words.join(" "));
                        // Session-5 candidate (1): single-step the spin loop and
                        // name exactly what it polls. ir_debug() decodes the
                        // instruction just executed; registers printed alongside.
                        println!("[{:7.2}s] STALL single-step trace (260 steps):", secs(now));
                        for i in 0..260 {
                            dmd.step();
                            let regs: Vec<String> = (0..13)
                                .map(|r| format!("{:x}", dmd.get_register(r)))
                                .collect();
                            println!("  step {:3} pc={:06x} ir={} r0..r12=[{}]",
                                i, dmd.get_pc(), dmd.ir_debug(), regs.join(","));
                        }
                        println!("[{:7.2}s] STALL trace done; duart now: {}",
                            secs(now), dmd.duart_debug());
                    }
                    // Complete when the loadable image (50,324 B) has certainly
                    // passed and the line has gone quiet: the post-download
                    // mpx-protocol handshake finishes within a second, after
                    // which mux idles at the desktop awaiting mouse input.
                    if burst_bytes > MUXTERM_TEXTDATA
                        && now.duration_since(last_rx_at) > Duration::from_secs(8)
                    {
                        let dl = last_rx_at.duration_since(mt).as_secs_f64();
                        println!(
                            "[{:7.2}s] muxterm download complete: {} bytes in {:.2}s (~{:.0} byte/s)",
                            secs(now),
                            burst_bytes,
                            dl,
                            burst_bytes as f64 / dl.max(0.001)
                        );
                        let tail: Vec<u8> = scan.iter().rev().take(200).rev().cloned().collect();
                        println!("host text tail: {:?}", String::from_utf8_lossy(&tail));
                        download_done_at = Some(now);
                        gest_t0 = Some(now + Duration::from_secs(6));
                        phase = Phase::Gestures;
                    }
                }
            }
            Phase::Gestures => {
                if let Some(g0) = gest_t0 {
                    let now = Instant::now();
                    if now >= g0 && gest_i < gestures.len() {
                        let (off, act) = &gestures[gest_i];
                        if now.duration_since(g0).as_millis() as u64 >= *off {
                            match act {
                                // The 5620 mouse registers are free-running
                                // quadrature counters: muxterm integrates
                                // sample deltas, with the y counter counting
                                // UP the screen, cursor starting at (0,0).
                                // Convert target screen coords to counter
                                // values whose deltas move the cursor there.
                                Act::Move(x, y) => {
                                    let dx = *x as i32 - cur_sx;
                                    let dy = *y as i32 - cur_sy;
                                    ctr_x = ctr_x.wrapping_add(dx as u16);
                                    ctr_y = ctr_y.wrapping_sub(dy as u16);
                                    cur_sx = *x as i32;
                                    cur_sy = *y as i32;
                                    dmd.mouse_move(ctr_x, ctr_y);
                                }
                                Act::Down(b) => dmd.mouse_down(*b),
                                Act::Up(b) => dmd.mouse_up(*b),
                                Act::Type(s) => kbq.extend(s.as_bytes()),
                                Act::Shot(label) => {
                                    let vram = dmd.video_ram();
                                    let n = FB_BYTES.min(vram.len());
                                    fbbuf[..n].copy_from_slice(&vram[..n]);
                                    shot_n += 1;
                                    dump_png(&shots_dir, shot_n, label, secs(now), &fbbuf);
                                }
                            }
                            gest_i += 1;
                        }
                    }
                    if gest_i >= gestures.len() {
                        phase = Phase::Done;
                        done_at = Some(Instant::now() + Duration::from_secs(3));
                    }
                }
            }
            Phase::Done => {}
        }

        // Periodic framebuffer-change snapshots.
        let now = Instant::now();
        if now.duration_since(last_fb_check) > Duration::from_millis(150) {
            last_fb_check = now;
            let vram = dmd.video_ram();
            let n = FB_BYTES.min(vram.len());
            fbbuf[..n].copy_from_slice(&vram[..n]);
            let h = fb_hash(&fbbuf);
            if h != last_hash {
                last_hash = h;
                if now.duration_since(last_shot) > Duration::from_millis(1200) && shot_n < 300 {
                    shot_n += 1;
                    dump_png(&shots_dir, shot_n, "fb", secs(now), &fbbuf);
                    last_shot = now;
                }
            }
        }

        if let Some(d) = done_at {
            if now > d {
                break;
            }
        }
        if now > hard_stop {
            println!("[{:7.2}s] hard stop", secs(now));
            break;
        }
    }

    // Final snapshot + summary.
    let vram = dmd.video_ram();
    let n = FB_BYTES.min(vram.len());
    fbbuf[..n].copy_from_slice(&vram[..n]);
    shot_n += 1;
    dump_png(&shots_dir, shot_n, "final", secs(Instant::now()), &fbbuf);
    println!(
        "summary: phase={phase:?} host_bytes={host_bytes_total} burst_bytes={burst_bytes} shots={shot_n}"
    );
}

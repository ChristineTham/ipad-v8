use dmd_core::Dmd;
use std::time::Instant;

fn try_reply(reply: Option<u8>) -> (u32, bool) {
    let mut dmd = Dmd::new();
    dmd.reset(1).expect("reset");
    let t0 = Instant::now();
    let mut sent = 0u32;
    while t0.elapsed().as_secs_f64() < 3.0 {
        dmd.run(20_000);
        while let Some(c) = dmd.keyboard_tx() {
            if let Some(r) = reply {
                dmd.keyboard_rx(r);
                sent += 1;
            }
            let _ = c;
        }
        while dmd.rs232_tx().is_some() {}
    }
    let pc = dmd.get_pc();
    let stuck = (0x2a40..=0x2a50).contains(&pc);
    (pc, stuck)
}

fn main() {
    let cands = [None, Some(0x00u8), Some(0xff), Some(0x02), Some(0x06), Some(0x01), Some(0x04), Some(0x08), Some(0x30)];
    for c in cands {
        let (pc, stuck) = try_reply(c);
        println!("reply {c:02x?}: final pc={pc:06x} stuck_in_wait_loop={stuck}");
    }
}

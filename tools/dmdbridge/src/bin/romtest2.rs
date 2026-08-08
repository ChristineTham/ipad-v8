//! Diagnostic 2: paced CPU + keyboard power-on injection vs the 8;7;3 wait loop.
use dmd_core::Dmd;
use std::time::{Duration, Instant};

fn main() {
    let mut dmd = Dmd::new();
    dmd.reset(1).expect("reset");
    let t0 = Instant::now();
    let mut last = Instant::now();
    let mut injected: u32 = 0;
    loop {
        // ~10 MHz pacing: 10k steps then ~1ms sleep
        dmd.run(10_000);
        std::thread::sleep(Duration::from_micros(900));
        while dmd.rs232_tx().is_some() {}
        while dmd.keyboard_tx().is_some() {}
        let el = t0.elapsed().as_secs_f64();
        if el > 5.0 && injected == 0 {
            println!("[{el:5.1}s] injecting keyboard 0xFF");
            dmd.keyboard_rx(0xff);
            injected = 1;
        }
        if el > 8.0 && injected == 1 {
            println!("[{el:5.1}s] injecting keyboard 0x00");
            dmd.keyboard_rx(0x00);
            injected = 2;
        }
        if last.elapsed() > Duration::from_millis(1000) {
            last = Instant::now();
            let mut pcs = Vec::new();
            for _ in 0..6 {
                dmd.run(1000);
                pcs.push(dmd.get_pc());
            }
            println!("[{el:5.1}s] pc: {pcs:x?}");
        }
        if el > 14.0 {
            break;
        }
    }
}

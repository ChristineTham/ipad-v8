//! Diagnostic: boot the 8;7;3 ROM standalone and sample the PC to find
//! where the RAM TEST spins in a headless loop.
use dmd_core::Dmd;
use std::time::{Duration, Instant};

fn main() {
    let mut dmd = Dmd::new();
    dmd.reset(1).expect("reset");
    let t0 = Instant::now();
    let mut last = Instant::now();
    let mut steps: u64 = 0;
    loop {
        dmd.run(10_000);
        steps += 10_000;
        // Pump the serial/keyboard queues like the bridge does.
        while dmd.rs232_tx().is_some() {}
        while dmd.keyboard_tx().is_some() {}
        if last.elapsed() > Duration::from_millis(1000) {
            last = Instant::now();
            let mut pcs = Vec::new();
            for _ in 0..8 {
                dmd.run(1000);
                pcs.push(dmd.get_pc());
            }
            println!(
                "[{:5.1}s] steps={:>12} dirty={} pc samples: {:x?}",
                t0.elapsed().as_secs_f64(),
                steps,
                dmd.video_ram_dirty(),
                pcs
            );
        }
        if t0.elapsed() > Duration::from_secs(20) {
            break;
        }
    }
}

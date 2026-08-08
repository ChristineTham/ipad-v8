use dmd_core::Dmd;
fn main() {
    let mut dmd = Dmd::new();
    dmd.reset(1).expect("reset");
    dmd.run(40_000_000);
    let mut hits = 0;
    for _ in 0..2_000_000 {
        dmd.step();
        let pc = dmd.get_pc();
        if pc == 0x2b11 || pc == 0x2b19 {
            println!(
                "at pc_after={pc:06x}: R8(expected?)={:02x} R6(got?)={:02x} R7={:02x} R0={:08x}",
                dmd.get_register(8) & 0xff,
                dmd.get_register(6) & 0xff,
                dmd.get_register(7) & 0xff,
                dmd.get_register(0)
            );
            hits += 1;
            if hits > 10 { break; }
        }
    }
    if hits == 0 { println!("comparison site never reached in 2M steps"); }
}

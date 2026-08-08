use dmd_core::Dmd;
fn main() {
    let mut dmd = Dmd::new();
    dmd.reset(1).expect("reset");
    dmd.run(40_000_000);
    let mut lines = std::collections::HashSet::new();
    for _ in 0..4000 {
        dmd.step();
        let d = dmd.ir_debug();
        let name = d.split("name: \"").nth(1).and_then(|x| x.split('\"').next()).unwrap_or("?").to_string();
        let pc = dmd.get_pc();
        let regs: Vec<String> = d.match_indices("register: Some(").map(|(i,_)| d[i+15..].split(')').next().unwrap_or("").to_string()).collect();
        let embeds: Vec<String> = d.match_indices("embedded: ").map(|(i,_)| d[i+10..].split(',').next().unwrap_or("").to_string()).collect();
        let line = format!("pc_after={pc:06x} {name:8} regs={regs:?} embed={embeds:?}");
        if lines.insert(line.clone()) {
            println!("{line}");
        }
    }
}

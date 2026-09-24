//! 测试公用：汇编一段源码并跑黄金模型。

use skein::asm;
use skein::golden::{Config, Machine};

/// 单 warp 的默认配置：指令级测试大多只关心一条 warp。
pub fn one_warp() -> Config {
    Config {
        nwarp: 1,
        ..Config::default()
    }
}

pub fn run_with(src: &str, config: Config) -> Machine {
    let output = match asm::assemble(src) {
        Ok(output) => output,
        Err(err) => panic!("汇编失败：{err}"),
    };
    let mut machine = Machine::new(output.words, config);
    machine.run();
    machine
}

pub fn run(src: &str) -> Machine {
    run_with(src, one_warp())
}

/// 某条 warp 上所有 lane 的寄存器值。
pub fn gprs(machine: &Machine, reg: usize, wid: usize) -> Vec<u32> {
    let warp = &machine.warps[wid];
    (0..warp.gpr.len())
        .map(|lane| warp.gpr[lane][reg])
        .collect()
}

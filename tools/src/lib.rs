//! Skein SIMT 处理器的仿真工具。
//!
//! - [`isa`]：编码定义，汇编器和黄金模型共用；
//! - [`asm`]：结构化汇编 -> IMEM 二进制镜像；
//! - [`golden`]：黄金模型，ISA 语义的唯一裁判。

pub mod asm;
pub mod case;
pub mod golden;
pub mod isa;

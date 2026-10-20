//! case：一次仿真的输入描述（`cases/*.toml`），黄金模型和 RTL testbench 共用同一份。
//!
//! case 只描述**输入**和要比对的窗口：程序（`.s` 或直接给指令字）、launch 形状、
//! 特殊寄存器、shared/global 初态、跑完要比对的内存窗口，外加可选的结束状态期望。
//! 语义期望（`c[i] = a[i] + b[i]` 这类）仍然写在 Rust 测试里。字段说明见
//! docs/plan.md 的"case（双仿真器对拍）"。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::asm;
use crate::golden::{Config, Machine, Space};
use crate::isa::{Sreg, Status, NUM_LANES, NUM_WARPS, WORD_BYTES};

/// 黄金模型的默认内存容量（RTL testbench 也按这个来）。
pub const SMEM_BYTES: usize = 32 * 1024;
pub const GMEM_BYTES: usize = 1 << 20;

/// case 文件（TOML）的原始字段。
#[derive(Deserialize, Debug)]
#[serde(deny_unknown_fields)]
pub struct Spec {
    /// 汇编源码，路径相对 case 文件所在目录；和 `words` 二选一
    pub program: Option<PathBuf>,
    /// 直接给指令字（汇编器编不出的保留编码用这个）；和 `program` 二选一
    pub words: Option<Vec<u32>>,
    #[serde(default = "default_warpsz")]
    pub warpsz: usize,
    #[serde(default = "default_nwarp")]
    pub nwarp: usize,
    pub block_dim: Option<usize>,
    #[serde(default = "default_grid")]
    pub grid: u32,
    /// 黄金模型的执行步数上限
    pub max_steps: Option<u64>,
    /// RTL 的时钟上限（默认 testbench 自己的 200000，bench 用例要放大）
    pub max_cycles: Option<u64>,
    /// 设备地址基址（上板时是 BO 的地址，可能 > 4 GB）；默认 0 = 核内偏移当绝对地址
    pub gmem_base: Option<u64>,
    /// 主机写的特殊寄存器（PTR_A/PTR_B/PTR_C/ARG0/ARG1/ARG2）
    #[serde(default)]
    pub sreg: BTreeMap<String, u32>,
    /// 初态
    #[serde(default)]
    pub init: Vec<Init>,
    /// 跑完要逐字比对的窗口
    #[serde(default)]
    pub check: Vec<Window>,
    pub expect: Option<Expect>,
}

/// 一段初态：`words` 或者 `gen` + `args` 二选一。
#[derive(Deserialize, Debug)]
#[serde(deny_unknown_fields)]
pub struct Init {
    pub space: String,
    pub addr: u32,
    pub words: Option<Vec<u32>>,
    pub gen: Option<String>,
    #[serde(default)]
    pub args: BTreeMap<String, i64>,
}

/// 要比对的内存窗口（RTL 必须和黄金模型逐字一致）。
#[derive(Deserialize, Debug)]
#[serde(deny_unknown_fields)]
pub struct Window {
    pub space: String,
    pub addr: u32,
    pub words: usize,
}

/// 结束状态的期望；不写就只做 RTL 与黄金模型的比对。
#[derive(Deserialize, Debug, Default)]
#[serde(deny_unknown_fields)]
pub struct Expect {
    /// 状态名，和 isa.rs 的 Status 一致（OK / BAD_INSN / …）
    pub status: Option<String>,
    /// 步数上界：抓"划分退化、白白多跑一遍"这类问题
    pub max_steps: Option<u64>,
    pub barriers: Option<u64>,
}

fn default_warpsz() -> usize {
    NUM_LANES
}

fn default_nwarp() -> usize {
    NUM_WARPS
}

fn default_grid() -> u32 {
    1
}

/// 一个已经读进来的 case。
#[derive(Debug)]
pub struct Case {
    pub name: String,
    pub path: PathBuf,
    pub spec: Spec,
}

/// RTL testbench 自报的形状（`tb_core --print-shape`）。
///
/// `warpsz` / `nwarp` 是硬件容量（每个 warp 的 lane 数、每条 block 的 warp 数），
/// `max_block_dim` 是一次启动能激活的线程数，`max_grid` 是 block 数容量。
#[derive(Deserialize, Debug, Clone, Copy)]
pub struct RtlShape {
    pub warpsz: usize,
    pub nwarp: usize,
    pub max_block_dim: usize,
    pub max_grid: u32,
}

impl Case {
    /// 读一个 `.toml`，名字取文件名；`program` 相对它所在目录解析。
    pub fn load(path: &Path) -> Result<Case, String> {
        Case::load_as(path, None)
    }

    /// 读一个目录下所有 `*.toml`（子目录也进去），名字取相对 `dir` 的路径、去掉
    /// 扩展名，比如 `cases/directed/sum.toml` -> `directed/sum`；按名字排序。
    pub fn load_dir(dir: &Path) -> Result<Vec<Case>, String> {
        let mut paths = Vec::new();
        collect_case_files(dir, &mut paths)?;
        paths.sort();
        paths
            .iter()
            .map(|path| {
                let name = path
                    .strip_prefix(dir)
                    .unwrap_or(path)
                    .with_extension("")
                    .to_string_lossy()
                    .replace('\\', "/");
                Case::load_as(path, Some(&name))
            })
            .collect()
    }

    fn load_as(path: &Path, name: Option<&str>) -> Result<Case, String> {
        let text =
            std::fs::read_to_string(path).map_err(|err| format!("{}: {err}", path.display()))?;
        let spec: Spec =
            toml::from_str(&text).map_err(|err| format!("{}: {err}", path.display()))?;
        let name = name.map(str::to_string).unwrap_or_else(|| {
            path.file_stem()
                .map(|stem| stem.to_string_lossy().into_owned())
                .unwrap_or_else(|| path.display().to_string())
        });
        if spec.program.is_none() == spec.words.is_none() {
            return Err(format!("{}: program 和 words 必须二选一", path.display()));
        }
        Ok(Case {
            name,
            path: path.to_path_buf(),
            spec,
        })
    }

    /// case 文件所在目录（`program` 等相对路径的基准）。
    pub fn dir(&self) -> PathBuf {
        self.path
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("."))
    }

    /// 汇编出来的指令字（`words` 直接给的那些原样返回）。
    pub fn program_words(&self) -> Result<Vec<u32>, String> {
        if let Some(words) = &self.spec.words {
            return Ok(words.clone());
        }
        let program = self
            .spec
            .program
            .as_ref()
            .ok_or_else(|| format!("{}: 没有 program 也没有 words", self.path.display()))?;
        let source_path = self.dir().join(program);
        let source = std::fs::read_to_string(&source_path)
            .map_err(|err| format!("{}: {err}", source_path.display()))?;
        asm::assemble(&source)
            .map(|output| output.words)
            .map_err(|err| format!("{}:{err}", source_path.display()))
    }

    /// 主机写的特殊寄存器，按名字（`PTR_A` / `S_PTR_A`）。
    pub fn sreg(&self, name: &str) -> Option<u32> {
        self.spec
            .sreg
            .iter()
            .find(|(key, _)| Sreg::from_name(key) == Sreg::from_name(name))
            .map(|(_, value)| *value)
    }

    /// 黄金模型的配置；`trace` 由调用方决定（case 里不写）。
    pub fn config(&self, trace: bool) -> Result<Config, String> {
        let mut sregs = Vec::new();
        for (name, value) in &self.spec.sreg {
            let sreg = Sreg::from_name(name)
                .ok_or_else(|| format!("{}: 不认识的特殊寄存器 {name}", self.path.display()))?;
            if !sreg.writable() {
                return Err(format!(
                    "{}: {} 是只读的，[sreg] 只能设置 PTR_A/PTR_B/PTR_C/ARG0/ARG1/ARG2",
                    self.path.display(),
                    sreg.text()
                ));
            }
            sregs.push((sreg, *value));
        }
        Ok(Config {
            warpsz: self.spec.warpsz,
            nwarp: self.spec.nwarp,
            block_dim: self.spec.block_dim,
            grid: self.spec.grid,
            smem_bytes: SMEM_BYTES,
            gmem_bytes: GMEM_BYTES,
            sregs,
            trace,
            max_steps: self.spec.max_steps.unwrap_or(1_000_000),
        })
    }

    /// 建好一台装好初态的黄金模型。
    pub fn machine(&self, trace: bool) -> Result<Machine, String> {
        let mut machine = Machine::new(self.program_words()?, self.config(trace)?);
        for init in &self.spec.init {
            let space = self.parse_space(&init.space)?;
            let words = self.init_words(init)?;
            let capacity = match space {
                Space::Smem => SMEM_BYTES,
                Space::Gmem => GMEM_BYTES,
            };
            if init.addr as usize + words.len() * WORD_BYTES as usize > capacity {
                return Err(format!(
                    "{}: [[init]] {} 在 0x{:x} 写 {} 个字越界",
                    self.path.display(),
                    init.space,
                    init.addr,
                    words.len()
                ));
            }
            for (index, word) in words.iter().enumerate() {
                machine.write_word(
                    space,
                    init.addr as usize + index * WORD_BYTES as usize,
                    *word,
                );
            }
        }
        Ok(machine)
    }

    /// 跑完之后，`[expect]` 里写了的东西是否都对得上；返回所有问题。
    pub fn check_golden(&self, machine: &Machine) -> Vec<String> {
        let mut problems = Vec::new();
        let Some(expect) = &self.spec.expect else {
            return problems;
        };
        if let Some(name) = &expect.status {
            match Status::from_text(&name.to_uppercase()) {
                Some(want) if want == machine.status => {}
                Some(want) => problems.push(format!(
                    "status 期望 {}，实际 {}",
                    want.text(),
                    machine.status.text()
                )),
                None => problems.push(format!("不认识的 status：{name}")),
            }
        }
        if let Some(max_steps) = expect.max_steps {
            if machine.steps > max_steps {
                problems.push(format!(
                    "步数 {} 超过上限 {max_steps}（划分退化了？）",
                    machine.steps
                ));
            }
        }
        if let Some(barriers) = expect.barriers {
            if machine.barriers != barriers {
                problems.push(format!(
                    "BAR 次数期望 {barriers}，实际 {}",
                    machine.barriers
                ));
            }
        }
        problems
    }

    /// block 的线程数：case 里没写就用满容量（`nwarp × warpsz`）。
    pub fn block_dim(&self) -> usize {
        self.spec
            .block_dim
            .unwrap_or(self.spec.nwarp * self.spec.warpsz)
    }

    /// 这个 case 能不能送进 RTL：形状要落在核的能力里，跑不了就返回原因（SKIP）。
    ///
    /// `shape` 由 testbench 自报（`tb_core --print-shape`，来自 `SK_core.shape_o`），
    /// 这样 runner 和 Makefile 里都不用再抄一份 lane 数。
    pub fn rtl_eligible(&self, shape: &RtlShape) -> Result<(), String> {
        if self.spec.warpsz != shape.warpsz {
            return Err(format!(
                "warpsz = {}，RTL 是 {}（同一份 RTL 只跑一种 warp 大小）",
                self.spec.warpsz, shape.warpsz
            ));
        }
        let block_dim = self.block_dim();
        // 非法 launch 参数（0 / 不是整数倍 / 超容量）本来就要报 BAD_LAUNCH，
        // 这种 case 照样送进 RTL——launch 校验走的就是板上主机写寄存器那条路
        let expect_bad_launch = self
            .spec
            .expect
            .as_ref()
            .is_some_and(|expect| expect.status.as_deref() == Some("BAD_LAUNCH"));
        if !expect_bad_launch {
            if block_dim == 0 || block_dim % shape.warpsz != 0 {
                return Err(format!("block_dim = {block_dim} 不是 warpsz 的整数倍"));
            }
            if block_dim > shape.max_block_dim {
                return Err(format!(
                    "block_dim = {block_dim}，RTL 一个 block 最多 {} 个线程",
                    shape.max_block_dim
                ));
            }
        }
        if self.spec.nwarp > shape.nwarp {
            return Err(format!(
                "case 里 nwarp = {}，RTL 只有 {} 条 warp",
                self.spec.nwarp, shape.nwarp
            ));
        }
        if self.spec.grid > shape.max_grid {
            return Err(format!(
                "grid = {}，RTL 一次最多 {} 个 block",
                self.spec.grid, shape.max_grid
            ));
        }
        Ok(())
    }

    /// 把一份输入落成 RTL testbench 能吃的文件，并给出它的命令行参数。
    pub fn materialize_rtl(&self, dir: &Path) -> Result<RtlInput, String> {
        let dir = self.work_dir(dir);
        std::fs::create_dir_all(&dir).map_err(|err| format!("{}: {err}", dir.display()))?;
        let stem = self.stem();
        let image = dir.join(format!("{stem}.bin"));
        write_words(&image, &self.program_words()?)?;
        let mut args = vec!["--image".to_string(), image.display().to_string()];
        args.push("--bdim".to_string());
        args.push(format!("{}", self.block_dim()));
        args.push("--nwarp".to_string());
        args.push(format!("{}", self.spec.nwarp));
        args.push("--grid".to_string());
        args.push(format!("{}", self.spec.grid));
        if let Some(base) = self.spec.gmem_base {
            args.push("--gmem-base".to_string());
            args.push(format!("{base:#x}"));
        }
        if let Some(cycles) = self.spec.max_cycles {
            args.push("--max-cycles".to_string());
            args.push(format!("{cycles}"));
        }
        let mut sregs: Vec<(&String, &u32)> = self.spec.sreg.iter().collect();
        sregs.sort();
        for (name, value) in sregs {
            let sreg = Sreg::from_name(name)
                .ok_or_else(|| format!("{}: 不认识的特殊寄存器 {name}", self.path.display()))?;
            args.push("--set".to_string());
            args.push(format!("{}={value:#x}", sreg.text()));
        }
        for (index, init) in self.spec.init.iter().enumerate() {
            let space = self.parse_space(&init.space)?;
            let path = dir.join(format!("{stem}.{}.{index}.bin", init.space));
            write_words(&path, &self.init_words(init)?)?;
            args.push(match space {
                Space::Smem => "--smem-init".to_string(),
                Space::Gmem => "--gmem-init".to_string(),
            });
            args.push(format!("{}", init.addr));
            args.push(path.display().to_string());
        }
        for window in &self.spec.check {
            self.parse_space(&window.space)?;
            args.push("--mem-window".to_string());
            args.push(window.space.to_lowercase());
            args.push(format!("{}", window.addr));
            args.push(format!("{}", window.words));
        }
        Ok(RtlInput { image, args })
    }

    /// 这个 case 在临时目录里的落脚点：按名字分目录，保持 `cases/` 的层次。
    pub fn work_dir(&self, root: &Path) -> PathBuf {
        root.join(self.name.replace('/', std::path::MAIN_SEPARATOR_STR))
    }

    /// 文件名部分（`kernels/matmul/rows16` -> `rows16`）。
    pub fn stem(&self) -> &str {
        self.name.rsplit('/').next().unwrap_or(&self.name)
    }

    /// 按 case 声明的窗口，从黄金模型里读出来（顺序和 `[[check]]` 一致）。
    pub fn read_windows(&self, machine: &Machine) -> Result<Vec<Vec<u32>>, String> {
        let mut windows = Vec::new();
        for window in &self.spec.check {
            let space = self.parse_space(&window.space)?;
            let capacity = match space {
                Space::Smem => SMEM_BYTES,
                Space::Gmem => GMEM_BYTES,
            };
            if window.addr as usize + window.words * WORD_BYTES as usize > capacity {
                return Err(format!(
                    "{}: [[check]] {} 在 0x{:x} 读 {} 个字越界",
                    self.path.display(),
                    window.space,
                    window.addr,
                    window.words
                ));
            }
            windows.push(
                (0..window.words)
                    .map(|index| {
                        machine.read_word(space, window.addr as usize + index * WORD_BYTES as usize)
                    })
                    .collect(),
            );
        }
        Ok(windows)
    }

    fn parse_space(&self, name: &str) -> Result<Space, String> {
        match name.to_lowercase().as_str() {
            "gmem" => Ok(Space::Gmem),
            "smem" => Ok(Space::Smem),
            other => Err(format!(
                "{}: space 只能是 gmem / smem，给的是 {other}",
                self.path.display()
            )),
        }
    }

    fn init_words(&self, init: &Init) -> Result<Vec<u32>, String> {
        match (&init.words, &init.gen) {
            (Some(words), None) => Ok(words.clone()),
            (None, Some(name)) => {
                generate(name, &init.args).map_err(|err| format!("{}: {err}", self.path.display()))
            }
            _ => Err(format!(
                "{}: [[init]] 的 words 和 gen 必须二选一",
                self.path.display()
            )),
        }
    }
}

/// RTL testbench 的输入：镜像 + 命令行参数（不含 `--dump-state`）。
#[derive(Debug)]
pub struct RtlInput {
    pub image: PathBuf,
    pub args: Vec<String>,
}

/// 递归收集 `*.toml`。
fn collect_case_files(dir: &Path, paths: &mut Vec<PathBuf>) -> Result<(), String> {
    let entries = std::fs::read_dir(dir).map_err(|err| format!("{}: {err}", dir.display()))?;
    for entry in entries {
        let path = entry
            .map_err(|err| format!("{}: {err}", dir.display()))?
            .path();
        if path.is_dir() {
            collect_case_files(&path, paths)?;
        } else if path.extension().is_some_and(|ext| ext == "toml") {
            paths.push(path);
        }
    }
    Ok(())
}

/// 小端写一串 32 位字。
fn write_words(path: &Path, words: &[u32]) -> Result<(), String> {
    let mut bytes = Vec::with_capacity(words.len() * WORD_BYTES as usize);
    for word in words {
        bytes.extend_from_slice(&word.to_le_bytes());
    }
    std::fs::write(path, bytes).map_err(|err| format!("{}: {err}", path.display()))
}

/// 具名数据生成器：有公式的测试数据放这里，case 里只写名字和参数。
///
/// 数值都挑得小，乘法不会溢出，方便和 Rust 参考实现比。
fn generate(name: &str, args: &BTreeMap<String, i64>) -> Result<Vec<u32>, String> {
    let count = |key: &str| -> Result<usize, String> {
        let value = *args
            .get(key)
            .ok_or_else(|| format!("生成器 {name} 需要参数 {key}"))?;
        usize::try_from(value).map_err(|_| format!("生成器 {name} 的参数 {key} 要是非负整数"))
    };
    match name {
        "vecadd_a" => {
            let n = count("n")?;
            Ok((0..n).map(|i| (i as i32 * 3 + 1) as u32).collect())
        }
        "vecadd_b" => {
            let n = count("n")?;
            Ok((0..n).map(|i| (i as i32 * 7 + 2) as u32).collect())
        }
        "matmul_a" => {
            let rows = count("rows")?;
            let n = MATMUL_N;
            Ok((0..rows * n).map(|i| ((i % 7) as i32 - 3) as u32).collect())
        }
        "matmul_b" => {
            let n = MATMUL_N;
            Ok((0..n * n).map(|i| ((i % 5) as i32 - 2) as u32).collect())
        }
        // M5 的 bench 用：和 matmul_a/b 同样的数，但大小由参数给
        "matmul64_a" => {
            let n = count("n")?;
            Ok((0..n).map(|i| ((i % 7) as i32 - 3) as u32).collect())
        }
        "matmul64_b" => {
            let n = count("n")?;
            Ok((0..n).map(|i| ((i % 5) as i32 - 2) as u32).collect())
        }
        other => Err(format!("不认识的生成器：{other}")),
    }
}

/// matmul kernel 里写死的内层维度（见 cases/kernels/matmul/matmul.s）。
pub const MATMUL_N: usize = 16;

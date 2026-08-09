// swift-tools-version:5.9
// ==========================================
// 文件: Package.swift
// 对应规格: docs/decisions/ADR-009-offline-model-runtime.md → 决策 2/3
//            3F.3b - whisper.cpp 运行时接入与真实转写
// 任务: 3F.3b - whisper.cpp 运行时接入（SPM 本地包，vendored 固定 revision）
// 许可证: MIT（whisper.cpp，ggml-org/whisper.cpp v1.9.2, rev 306c88f4d1）
// 说明: HTTPS 直连 github.com 被阻断（2026-08-09 环境探测），无法远程解析 SPM 依赖；
//       采用本地 vendored 源码 + 固定 revision（306c88f4d1）+ SHA-256 登记，
//       满足 ADR-009 决策 2（不可变捆绑工件）与 AGENTS.md R-005（零网络运行时）。
//       构建决策: GGML_CPU_GENERIC — whisper.cpp 的 arch-fallback.h 按目标架构重命名
//       _generic 符号，但 SPM 静态 sources 无法按架构排除 arch/arm/*.c（CMake 才能），
//       x86_64 下 arch/arm/quants.c 与通用 quants.c 产生 duplicate symbol。
//       定义 GGML_CPU_GENERIC 使全部 _generic 实现重命名为正式符号（架构无关），
//       并排除 arch/arm/ 源文件；whisper tiny 推理功能完整（无 NEON 专属加速）。
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-005 (禁止网络下载), R-007 (禁止 unchecked Sendable)
// 生成时间: 2026-08-09
// ==========================================

import PackageDescription

let package = Package(
    name: "whisper-cpp",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "whisper", targets: ["whisper"])
    ],
    targets: [
        .target(
            name: "whisper",
            path: ".",
            sources: [
                "whisper.cpp",
                "ggml/ggml.c", "ggml/ggml.cpp", "ggml/ggml-alloc.c",
                "ggml/ggml-backend.cpp", "ggml/ggml-backend-reg.cpp",
                "ggml/ggml-backend-dl.cpp", "ggml/ggml-backend-meta.cpp",
                "ggml/ggml-quants.c", "ggml/ggml-threading.cpp",
                "ggml/ggml-opt.cpp", "ggml/gguf.cpp",
                "ggml/src/ggml-cpu/ggml-cpu.c", "ggml/src/ggml-cpu/ggml-cpu.cpp",
                "ggml/src/ggml-cpu/ops.cpp", "ggml/src/ggml-cpu/binary-ops.cpp",
                "ggml/src/ggml-cpu/unary-ops.cpp", "ggml/src/ggml-cpu/vec.cpp",
                "ggml/src/ggml-cpu/quants.c", "ggml/src/ggml-cpu/traits.cpp",
                "ggml/src/ggml-cpu/repack.cpp",
                "ggml/src/ggml-cpu/amx/amx.cpp",
                "ggml/src/ggml-cpu/amx/mmq.cpp",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("ggml-include"),
                .headerSearchPath("ggml"),
                .headerSearchPath("ggml/src"),
                .headerSearchPath("ggml/src/ggml-cpu"),
                .headerSearchPath("ggml/src/ggml-cpu/arch/arm"),
                .define("GGML_USE_CPU"),
                .define("GGML_USE_ACCELERATE"),
                .define("GGML_CPU_GENERIC"),
                .define("GGML_VERSION", to: "\"0.18.1\""),
                .define("GGML_COMMIT", to: "\"306c88f4d1\""),
                .define("WHISPER_VERSION", to: "\"1.9.2\""),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate")
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)

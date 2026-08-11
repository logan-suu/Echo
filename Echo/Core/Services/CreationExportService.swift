// ==========================================
// 文件: CreationExportService.swift
// 对应规格: docs/decisions/ADR-013-creation-export-boundary.md → 决策 4 (Markdown/PDF/系统 share 导出),
//            docs/01-spec/用户故事与验收标准规格书.md → US-SYN-003 AC-3 (导出 PDF/Markdown),
//            US-SYN-004 AC-4 (分享/导出/打印)
// 任务: 3F.9 - Apple Translation 与 grounded creation
// AC 覆盖: US-SYN-003 AC-3 ✅ (文字预览/复制/导出为 PDF/Markdown), AC-6 ✅ (exportFormat 审计字段),
//          US-SYN-004 AC-4 ✅ (分享/导出/打印), ADR-013 决策 4 ✅ (系统 share/export, 无 notes:// 深链)
// 架构约束: Core 服务; 纯函数 (输入 CreativeOutput → 输出 Markdown/PDF/分享文本);
//           禁止 notes://echo/... 深链 (ADR-013 决策 4 — Notes 交接仅用系统 share/export 流)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，struct 成员需 nonisolated
// 生成时间: 2026-08-11
// ==========================================

import Foundation
import UIKit

/// 创作导出服务 — Markdown / PDF / 系统分享文本 (US-SYN-003 AC-3, ADR-013 决策 4)。
///
/// ## 职责 (ADR-013 决策 4)
/// - Markdown: 标题 + 段落 + 溯源锚点（`[🔗 MemoryID:xxx]` / `[⚠️ NoSource]`）
/// - PDF: 经 `UIGraphicsPDFRenderer` 渲染为 PDF Data
/// - Share text: 纯文本（不含锚点标记），供系统 share sheet 使用
/// - **Notes 交接仅用系统 share/export 流，不伪造 `notes://` URL**
enum CreationExportService {

    // MARK: - Markdown (US-SYN-003 AC-3)

    /// 生成 Markdown — 标题 + 段落 + 溯源锚点 (US-SYN-002 AC-1)。
    static func markdown(from output: CreativeOutput) -> String {
        var lines: [String] = []
        if let title = output.title {
            lines.append("# \(title)")
            lines.append("")
        }
        for paragraph in output.paragraphs {
            if let anchor = paragraph.anchor {
                if anchor.hasSource {
                    lines.append("> [🔗 MemoryID:\(anchor.memoryID.uuidString.prefix(8))…]")
                } else {
                    lines.append("> [⚠️ NoSource]")
                }
            } else {
                lines.append("> [⚠️ NoSource]")
            }
            lines.append(paragraph.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - PDF (US-SYN-003 AC-3)

    /// 生成 PDF Data — 经 `UIGraphicsPDFRenderer` 渲染 Markdown 文本。
    static func pdf(from output: CreativeOutput) async throws -> Data {
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: 595, height: 842),
            format: UIGraphicsPDFRendererFormat()
        )
        let text = markdown(from: output)
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: UIFont.systemFont(ofSize: 12)]
        )
        let data = renderer.pdfData { context in
            context.beginPage()
            attributed.draw(in: CGRect(x: 40, y: 40, width: 515, height: 762))
        }
        return data
    }

    // MARK: - Share Text (US-SYN-003 AC-3, US-SYN-004 AC-4)

    /// 生成系统 share 纯文本 — 段落拼接，不含锚点标记（供 ShareLink / share sheet）。
    static func shareText(from output: CreativeOutput) -> String {
        var lines: [String] = []
        if let title = output.title {
            lines.append(title)
            lines.append("")
        }
        for paragraph in output.paragraphs {
            lines.append(paragraph.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

"""Append the evidence updates to the original 17-page plan PDF.

The original pages are copied unchanged. Output is a candidate in build/ and
must be visually checked before replacing the published PDF.
"""

from html import escape
from io import BytesIO
from pathlib import Path
import re

from pypdf import PdfReader, PdfWriter
from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import PageBreak, Paragraph, SimpleDocTemplate, Spacer


ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
MARKDOWN = DOCS / "紫光同创_FPGA_任意角度畸变矫正_初始方案.md"
ORIGINAL = ROOT / "tools" / "assets" / "initial_plan_base_17p.pdf"
CANDIDATE = ROOT / "build" / "initial_plan_with_package1_update.pdf"


def main() -> None:
    source = MARKDOWN.read_text(encoding="utf-8")
    sections = []
    for heading, expected in [
        ("A.7 资料包 1 实证补充（2026-10-03）", 6),
        ("A.8 PDS Lite 后续离线测试补充（2026-10-03）", 5),
        ("A.9 Lite HMIC 安装后的复测结论（2026-10-03）", 5),
        ("A.10 时钟复测与 PC 黄金模型（2026-10-03）", 4),
        ("A.11 OV5640 鱼眼镜头的离线准备（2026-10-05）", 4),
        ("A.12 团队使用 Codex 与 Git 协作（2026-10-07）", 4),
    ]:
        marker = f"## {heading}"
        if source.count(marker) != 1:
            raise RuntimeError(f"Heading must occur once: {heading}")
        annex = source.split(marker, 1)[1].split("\n## ", 1)[0].strip()
        lines = [line.strip() for line in annex.splitlines() if line.strip()]
        intro = lines[0]
        points = []
        for line in lines[1:]:
            match = re.fullmatch(r"(\d+)\. (.+)", line)
            if not match:
                raise RuntimeError(f"Unexpected annex line: {line}")
            points.append((match.group(1), match.group(2)))
        if len(points) != expected:
            raise RuntimeError(f"Expected {expected} evidence updates in {heading}")
        sections.append((heading, intro, points))

    pdfmetrics.registerFont(TTFont("SimHei", r"C:\Windows\Fonts\simhei.ttf"))
    title_style = ParagraphStyle(
        "title", fontName="SimHei", fontSize=15, leading=23,
        textColor=colors.HexColor("#242424"), alignment=TA_CENTER,
        spaceAfter=24,
    )
    body_style = ParagraphStyle(
        "body", fontName="SimHei", fontSize=10.2, leading=19,
        textColor=colors.HexColor("#242424"), spaceAfter=11,
        wordWrap="CJK",
    )
    point_style = ParagraphStyle(
        "point", parent=body_style, leftIndent=18, firstLineIndent=-18,
        spaceAfter=12,
    )

    def as_pdf_text(value: str) -> str:
        # Keep code spans visibly distinct without needing an additional font.
        return escape(value).replace("`", "")

    story = []
    for section_index, (heading, intro, points) in enumerate(sections):
        if section_index:
            story.append(PageBreak())
        story.append(Paragraph(heading, title_style))
        story.append(Paragraph(as_pdf_text(intro), body_style))
        story.append(Spacer(1, 7))
        for number, value in points:
            story.append(Paragraph(f"{number}. {as_pdf_text(value)}", point_style))
        story.append(Spacer(1, 11))
        if section_index == 0:
            reference = "完整来源、页码、日志和后续验收路线：同目录《盘古50K资料包1_研读记录.md》。"
        elif section_index == 3:
            reference = "完整时钟证据、运行命令和数值测试：同目录《时钟约束与PC黄金模型_2026-10-03.md》。"
        elif section_index == 4:
            reference = "完整鱼眼模型说明、测试与到货后步骤：同目录《鱼眼镜头离线准备_2026-10-05.md》。"
        elif section_index == 5:
            reference = "完整分工、分支、文件边界与验收规则：同目录《团队协作规范.md》。"
        else:
            reference = "完整测试矩阵和日志路径：同目录《PDS_Lite_离线验证记录_2026-10-03.md》。"
        story.append(Paragraph(reference, body_style))

    annex_buffer = BytesIO()
    SimpleDocTemplate(
        annex_buffer, pagesize=A4,
        leftMargin=55, rightMargin=55,
        topMargin=54, bottomMargin=50,
        title="资料包 1 实证补充与 PDS Lite 离线验证",
    ).build(story)
    annex_buffer.seek(0)

    old_pdf = PdfReader(ORIGINAL)
    if len(old_pdf.pages) != 17:
        raise RuntimeError(f"Expected 17 original pages, got {len(old_pdf.pages)}")
    new_pdf = PdfReader(annex_buffer)
    writer = PdfWriter()
    for page in old_pdf.pages:
        writer.add_page(page)
    for page in new_pdf.pages:
        writer.add_page(page)
    writer.add_metadata({"/Title": "紫光同创 FPGA 任意角度畸变矫正初始方案及资料包1复测补充"})
    CANDIDATE.parent.mkdir(parents=True, exist_ok=True)
    with CANDIDATE.open("wb") as output:
        writer.write(output)
    print(f"Candidate: {CANDIDATE}; original={len(old_pdf.pages)}, annex={len(new_pdf.pages)}, total={len(writer.pages)}")


if __name__ == "__main__":
    main()

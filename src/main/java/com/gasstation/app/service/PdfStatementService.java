package com.gasstation.app.service;

import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.PDPage;
import org.apache.pdfbox.pdmodel.PDPageContentStream;
import org.apache.pdfbox.pdmodel.PDPageContentStream.AppendMode;
import org.apache.pdfbox.pdmodel.common.PDRectangle;
import org.apache.pdfbox.pdmodel.font.PDFont;
import org.apache.pdfbox.pdmodel.font.PDType0Font;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;

public class PdfStatementService {

    private static final String FONT_RESOURCE = "/fonts/DejaVuSans.ttf";

    public Path exportStatementText(String titleSlug, String statementText, Path outDir) throws IOException {
        Files.createDirectories(outDir);

        String safe = (titleSlug == null || titleSlug.isBlank())
                ? "statement"
                : titleSlug.replaceAll("[^a-zA-Z0-9._-]", "_");

        String ts = LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyyMMdd_HHmmss"));
        Path out = outDir.resolve(safe + "_" + ts + ".pdf");

        String[] lines = (statementText == null ? "" : statementText).split("\\R");

        float fontSize = 10f;
        float margin = 40f;
        float leading = 1.2f * fontSize;

        PDRectangle pageSize = PDRectangle.LETTER;
        float maxWidth = pageSize.getWidth() - (2 * margin);

        try (PDDocument doc = new PDDocument()) {

            PDFont font = loadUnicodeFont(doc);

            PDPage page = new PDPage(pageSize);
            doc.addPage(page);

            float yStart = pageSize.getHeight() - margin;
            float y = yStart;

            PDPageContentStream cs = new PDPageContentStream(doc, page, AppendMode.APPEND, true, true);
            cs.beginText();
            cs.setFont(font, fontSize);
            cs.newLineAtOffset(margin, y);

            for (String rawLine : lines) {

                // page break
                if (y - leading < margin) {
                    cs.endText();
                    cs.close();

                    page = new PDPage(pageSize);
                    doc.addPage(page);

                    y = yStart;

                    cs = new PDPageContentStream(doc, page, AppendMode.APPEND, true, true);
                    cs.beginText();
                    cs.setFont(font, fontSize);
                    cs.newLineAtOffset(margin, y);
                }

                String line = safeFit(rawLine, font, fontSize, maxWidth);
                cs.showText(line);
                cs.newLineAtOffset(0, -leading);
                y -= leading;
            }

            cs.endText();
            cs.close();

            doc.save(out.toFile());
        }

        return out;
    }

    private PDFont loadUnicodeFont(PDDocument doc) throws IOException {
        // 1) classpath
        try (InputStream is = PdfStatementService.class.getResourceAsStream(FONT_RESOURCE)) {
            if (is != null) return PDType0Font.load(doc, is, true);
        }

        // 2) dev fallback (Eclipse run)
        Path p = Path.of("src/main/resources" + FONT_RESOURCE);
        if (Files.exists(p)) {
            try (InputStream is = Files.newInputStream(p)) {
                return PDType0Font.load(doc, is, true);
            }
        }

        throw new IOException("Unicode font not found at " + FONT_RESOURCE +
                " (also tried " + p.toAbsolutePath() + ")");
    }

    private static String safeFit(String s, PDFont font, float fontSize, float maxWidth) throws IOException {
        if (s == null) return "";

        // fast path
        if (stringWidth(s, font, fontSize) <= maxWidth) return s;

        // clip with ellipsis
        final String ell = "…";
        int lo = 0, hi = s.length();

        while (lo < hi) {
            int mid = (lo + hi + 1) / 2;
            String candidate = s.substring(0, mid) + ell;

            if (stringWidth(candidate, font, fontSize) <= maxWidth) lo = mid;
            else hi = mid - 1;
        }

        return (lo <= 0) ? ell : s.substring(0, lo) + ell;
    }

    private static float stringWidth(String s, PDFont font, float fontSize) throws IOException {
        return (font.getStringWidth(s) / 1000f) * fontSize;
    }
}

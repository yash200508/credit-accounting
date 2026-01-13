package com.gasstation.app.util;

import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

public final class CsvUtil {

    private CsvUtil() {}

    public static void write(Path file, List<String> header, List<List<String>> rows) throws IOException {
        Files.createDirectories(file.getParent());
        try (BufferedWriter w = Files.newBufferedWriter(file, StandardCharsets.UTF_8)) {
            if (header != null && !header.isEmpty()) {
                w.write(line(header));
                w.newLine();
            }
            for (List<String> r : rows) {
                w.write(line(r));
                w.newLine();
            }
        }
    }

    private static String line(List<String> cols) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < cols.size(); i++) {
            if (i > 0) sb.append(',');
            sb.append(escape(cols.get(i)));
        }
        return sb.toString();
    }

    private static String escape(String s) {
        if (s == null) return "";
        String v = s;
        boolean need = v.contains(",") || v.contains("\"") || v.contains("\n") || v.contains("\r");
        v = v.replace("\"", "\"\"");
        return need ? "\"" + v + "\"" : v;
    }
}

package com.gasstation.app;

import com.gasstation.app.dao.CustomerDao;
import com.gasstation.app.model.Customer;
import javafx.beans.property.SimpleStringProperty;
import javafx.collections.FXCollections;
import javafx.collections.ObservableList;
import javafx.geometry.Insets;
import javafx.scene.control.*;
import javafx.scene.layout.*;
import javafx.stage.FileChooser;
import org.apache.poi.ss.usermodel.CellType;
import org.apache.poi.ss.usermodel.DateUtil;
import org.apache.poi.ss.usermodel.Row;
import org.apache.poi.ss.usermodel.Sheet;
import org.apache.poi.ss.usermodel.Workbook;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.util.*;

public class CustomerImportScreen extends BorderPane {

    private final AppNavigator nav;
    private final CustomerDao customerDao = new CustomerDao();

    private final Label fileLabel = new Label("No file selected");
    private final Button backBtn = new Button("← Back");
    private final Button chooseBtn = new Button("Choose Excel File (.xlsx)");
    private final Button importBtn = new Button("Import Customers");
    private final TextArea logArea = new TextArea();

    private final TableView<Map<String, String>> previewTable = new TableView<>();
    private final ObservableList<Map<String, String>> previewData = FXCollections.observableArrayList();

    private File selectedFile;

    public CustomerImportScreen(AppNavigator nav) {
        this.nav = nav;
        setPadding(new Insets(12));

        importBtn.setDisable(true);
        logArea.setEditable(false);
        logArea.setWrapText(true);
        logArea.setPrefRowCount(10);

        previewTable.setItems(previewData);
        previewTable.setPlaceholder(new Label("Preview will appear here after selecting a file."));

        setTop(buildTop());
        setCenter(buildCenter());
        setBottom(buildBottom());

        chooseBtn.setOnAction(e -> chooseFile());
        importBtn.setOnAction(e -> importFile());
        backBtn.setOnAction(e -> nav.showImportHub());
    }

    private Pane buildTop() {
        Label title = new Label("Import Customers (Excel)");
        title.setStyle("-fx-font-size: 16px; -fx-font-weight: bold;");

        Label help = new Label(
                "Required headers: Name, Phone\n" +
                "Optional: Address, Notes, Active, CreditLimit, CreditLimitPaise, DueDays, GraceDays\n" +
                "Phone is stored as last 10 digits. Duplicate phones are skipped."
        );
        help.setStyle("-fx-text-fill: #666;");

        HBox row = new HBox(10, backBtn, chooseBtn, importBtn);

        VBox box = new VBox(8, title, help, fileLabel, row);
        box.setPadding(new Insets(0, 0, 12, 0));
        return box;
    }

    private Pane buildCenter() {
        VBox box = new VBox(8, new Label("Preview (first 10 rows)"), previewTable);
        VBox.setVgrow(previewTable, Priority.ALWAYS);
        return box;
    }

    private Pane buildBottom() {
        VBox box = new VBox(8, new Label("Import Log"), logArea);
        box.setPadding(new Insets(12, 0, 0, 0));
        return box;
    }

    private void chooseFile() {
        FileChooser fc = new FileChooser();
        fc.setTitle("Select Customers Excel file");
        fc.getExtensionFilters().add(new FileChooser.ExtensionFilter("Excel Files", "*.xlsx"));

        File f = fc.showOpenDialog(getScene() == null ? null : getScene().getWindow());
        if (f == null) return;

        selectedFile = f;
        fileLabel.setText("Selected: " + f.getAbsolutePath());
        logArea.clear();
        log("Selected file: " + f.getName());

        try {
            List<Map<String, String>> rows = readRows(f, 10);
            buildPreviewColumns(rows);
            previewData.setAll(rows);

            Set<String> keys = rows.isEmpty() ? Set.of() : rows.get(0).keySet();
            if (!keys.contains("Name") || !keys.contains("Phone")) {
                log("⚠ Missing required headers. Found headers: " + keys);
                importBtn.setDisable(true);
                return;
            }

            importBtn.setDisable(false);
            log("Preview loaded. Ready to import.");
        } catch (Exception ex) {
            importBtn.setDisable(true);
            previewData.clear();
            previewTable.getColumns().clear();
            log("ERROR reading file: " + ex.getMessage());
            ex.printStackTrace();
        }
    }

    private void importFile() {
        if (selectedFile == null) return;

        int imported = 0;
        int skipped = 0;
        List<Map<String, String>> failedRows = new ArrayList<>();

        try {
            List<Map<String, String>> allRows = readRows(selectedFile, Integer.MAX_VALUE);
            if (allRows.isEmpty()) {
                log("No data rows found.");
                return;
            }

            Set<String> existingPhones = new HashSet<>();
            try {
                customerDao.listAll().forEach(c -> existingPhones.add(normalizePhone(c.getPhone())));
            } catch (Exception ignore) {}

            for (int i = 0; i < allRows.size(); i++) {
                Map<String, String> r = allRows.get(i);

                String name = safe(r.get("Name")).trim();
                String phone = normalizePhone(r.get("Phone"));

                if (name.isEmpty() || phone.isEmpty()) {
                    skipped++;
                    log("SKIP row " + (i + 2) + ": missing required fields (Name/Phone)");
                    failedRows.add(withFailReason(r, "Missing required fields (Name/Phone)"));
                    continue;
                }

                if (existingPhones.contains(phone)) {
                    skipped++;
                    log("SKIP row " + (i + 2) + ": duplicate phone: " + phone);
                    failedRows.add(withFailReason(r, "Duplicate phone: " + phone));
                    continue;
                }

                Customer c = new Customer();
                c.setName(name);
                c.setPhone(phone);
                c.setAddress(safe(r.get("Address")).trim());
                c.setNotes(safe(r.get("Notes")).trim());

                c.setIsActive(parseActive(r.get("Active")));
                c.setDueDays(parseIntOrDefault(r.get("DueDays"), 30));
                c.setGraceDays(Math.max(0, parseIntOrDefault(r.get("GraceDays"), 0)));

                long creditLimitPaise = 0;
                String clPaise = safe(r.get("CreditLimitPaise"));
                String cl = safe(r.get("CreditLimit"));
                if (!clPaise.isEmpty()) {
                    creditLimitPaise = parseLongOrZero(clPaise);
                } else if (!cl.isEmpty()) {
                    creditLimitPaise = rupeesToPaise(cl);
                }
                if (creditLimitPaise < 0) creditLimitPaise = 0;
                c.setCreditLimitPaise(creditLimitPaise);

                try {
                    customerDao.insert(c);
                    existingPhones.add(phone);
                    imported++;
                } catch (Exception ex) {
                    skipped++;
                    log("SKIP row " + (i + 2) + ": " + ex.getMessage());
                    failedRows.add(withFailReason(r, ex.getMessage()));
                }
            }

            log("DONE ✅ Imported=" + imported + " | Skipped=" + skipped);
            if (!failedRows.isEmpty()) writeFailedRowsExcel(failedRows);

        } catch (Exception ex) {
            log("ERROR importing: " + ex.getMessage());
            ex.printStackTrace();
        }
    }

    private Map<String, String> withFailReason(Map<String, String> row, String reason) {
        Map<String, String> out = new LinkedHashMap<>(row);
        out.put("FAIL_REASON", reason);
        return out;
    }

    private void writeFailedRowsExcel(List<Map<String, String>> failedRows) {
        if (failedRows.isEmpty() || selectedFile == null) return;

        File outFile = new File(selectedFile.getParentFile(),
                "customers-not-imported-" + System.currentTimeMillis() + ".xlsx");

        try (Workbook wb = new XSSFWorkbook()) {
            Sheet sheet = wb.createSheet("NOT_IMPORTED");

            LinkedHashSet<String> headerSet = new LinkedHashSet<>();
            for (Map<String, String> row : failedRows) headerSet.addAll(row.keySet());
            List<String> headers = new ArrayList<>(headerSet);

            Row headerRow = sheet.createRow(0);
            for (int c = 0; c < headers.size(); c++) {
                org.apache.poi.ss.usermodel.Cell cell = headerRow.createCell(c);
                cell.setCellValue(headers.get(c));
            }

            for (int r = 0; r < failedRows.size(); r++) {
                Row rr = sheet.createRow(r + 1);
                Map<String, String> row = failedRows.get(r);
                for (int c = 0; c < headers.size(); c++) {
                    org.apache.poi.ss.usermodel.Cell cell = rr.createCell(c);
                    cell.setCellValue(safe(row.get(headers.get(c))));
                }
            }

            for (int i = 0; i < headers.size(); i++) sheet.autoSizeColumn(i);

            try (FileOutputStream fos = new FileOutputStream(outFile)) {
                wb.write(fos);
            }

            log("⚠ Exported failed rows to: " + outFile.getAbsolutePath());
        } catch (Exception e) {
            log("ERROR exporting failed rows: " + e.getMessage());
        }
    }

    private List<Map<String, String>> readRows(File f, int limit) throws Exception {
        try (FileInputStream fis = new FileInputStream(f);
             Workbook wb = new XSSFWorkbook(fis)) {

            Sheet sheet = wb.getSheetAt(0);
            Iterator<Row> it = sheet.rowIterator();
            if (!it.hasNext()) return List.of();

            Row headerRow = it.next();
            List<String> headers = readHeaders(headerRow);

            List<Map<String, String>> out = new ArrayList<>();
            int count = 0;
            while (it.hasNext() && count < limit) {
                Row row = it.next();
                Map<String, String> map = new LinkedHashMap<>();
                for (int i = 0; i < headers.size(); i++) {
                    org.apache.poi.ss.usermodel.Cell cell =
                            row.getCell(i, Row.MissingCellPolicy.RETURN_BLANK_AS_NULL);
                    map.put(headers.get(i), cellToString(cell));
                }
                boolean any = map.values().stream().anyMatch(v -> v != null && !v.trim().isEmpty());
                if (!any) continue;

                out.add(map);
                count++;
            }
            return out;
        }
    }

    private List<String> readHeaders(Row headerRow) {
        List<String> headers = new ArrayList<>();
        int last = headerRow.getLastCellNum();
        for (int i = 0; i < last; i++) {
            org.apache.poi.ss.usermodel.Cell cell =
                    headerRow.getCell(i, Row.MissingCellPolicy.RETURN_BLANK_AS_NULL);
            String h = cellToString(cell).trim();
            if (h.isEmpty()) h = "COL" + (i + 1);
            headers.add(normalizeHeader(h));
        }
        return headers;
    }

    private String normalizeHeader(String h) {
        String t = h.trim();
        if (equalsAny(t, "customer", "customername", "customer_name")) return "Name";
        if (equalsAny(t, "mobile", "phonenumber", "phone_number")) return "Phone";
        if (equalsAny(t, "credit_limit", "limit", "creditlimit")) return "CreditLimit";
        if (equalsAny(t, "creditlimitpaise", "credit_limit_paise", "limitpaise")) return "CreditLimitPaise";
        if (equalsAny(t, "duedays", "due_days")) return "DueDays";
        if (equalsAny(t, "gracedays", "grace_days")) return "GraceDays";
        return capitalizeKey(t);
    }

    private boolean equalsAny(String raw, String... options) {
        String a = raw.replaceAll("[^A-Za-z0-9]", "").toLowerCase();
        for (String o : options) {
            String b = o.replaceAll("[^A-Za-z0-9]", "").toLowerCase();
            if (a.equals(b)) return true;
        }
        return false;
    }

    private String capitalizeKey(String s) {
        if (s.isEmpty()) return s;
        if (Character.isUpperCase(s.charAt(0))) return s;
        return Character.toUpperCase(s.charAt(0)) + s.substring(1);
    }

    private void buildPreviewColumns(List<Map<String, String>> rows) {
        previewTable.getColumns().clear();
        if (rows == null || rows.isEmpty()) return;

        Map<String, String> first = rows.get(0);
        for (String key : first.keySet()) {
            TableColumn<Map<String, String>, String> col = new TableColumn<>(key);
            col.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().getOrDefault(key, "")));
            previewTable.getColumns().add(col);
        }
    }

    private String cellToString(org.apache.poi.ss.usermodel.Cell cell) {
        if (cell == null) return "";
        CellType t = cell.getCellType();

        if (t == CellType.STRING) {
            return cell.getStringCellValue() == null ? "" : cell.getStringCellValue();
        }
        if (t == CellType.NUMERIC) {
            if (DateUtil.isCellDateFormatted(cell)) {
                return cell.getLocalDateTimeCellValue().toLocalDate().toString();
            }
            double d = cell.getNumericCellValue();
            if (Math.floor(d) == d) return Long.toString((long) d);
            return Double.toString(d);
        }
        if (t == CellType.BOOLEAN) {
            return Boolean.toString(cell.getBooleanCellValue());
        }
        if (t == CellType.FORMULA) {
            try {
                return cell.getStringCellValue();
            } catch (Exception e) {
                try {
                    return Double.toString(cell.getNumericCellValue());
                } catch (Exception ex) {
                    return "";
                }
            }
        }
        return "";
    }

    private String normalizePhone(String s) {
        if (s == null) return "";
        String digits = s.replaceAll("\\D", "");
        if (digits.length() >= 10) return digits.substring(digits.length() - 10);
        return "";
    }

    private int parseActive(String s) {
        if (s == null) return 1;
        String t = s.trim().toLowerCase();
        if (t.isEmpty()) return 1;
        if (t.equals("0") || t.equals("false") || t.equals("no") || t.equals("inactive")) return 0;
        return 1;
    }

    private int parseIntOrDefault(String s, int fallback) {
        if (s == null || s.trim().isEmpty()) return fallback;
        try { return Integer.parseInt(s.trim()); }
        catch (Exception e) { return fallback; }
    }

    private long parseLongOrZero(String s) {
        if (s == null || s.trim().isEmpty()) return 0;
        try { return Long.parseLong(s.trim()); }
        catch (Exception e) { return 0; }
    }

    private long rupeesToPaise(String s) {
        if (s == null) return 0;
        String t = s.trim();
        if (t.isEmpty()) return 0;
        t = t.replace("₹", "").replace(",", "").trim();
        try {
            if (!t.contains(".")) return Long.parseLong(t) * 100L;
            String[] parts = t.split("\\.");
            long rupees = Long.parseLong(parts[0].isEmpty() ? "0" : parts[0]);
            String p = (parts.length > 1) ? parts[1] : "0";
            if (p.length() == 1) p = p + "0";
            if (p.length() > 2) p = p.substring(0, 2);
            long paise = Long.parseLong(p);
            return rupees * 100L + paise;
        } catch (Exception e) {
            return 0;
        }
    }

    private String safe(String s) {
        return s == null ? "" : s;
    }

    private void log(String msg) {
        logArea.appendText(msg + "\n");
    }
}

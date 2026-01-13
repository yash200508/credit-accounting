package com.gasstation.app;

import com.gasstation.app.dao.CustomerDao;
import com.gasstation.app.dao.TransactionDao;
import com.gasstation.app.model.Customer;
import com.gasstation.app.model.Transaction;
import javafx.geometry.Insets;
import javafx.scene.control.*;
import javafx.scene.layout.BorderPane;
import javafx.scene.layout.HBox;
import javafx.scene.layout.VBox;
import javafx.stage.FileChooser;


import org.apache.poi.common.usermodel.HyperlinkType;
import org.apache.poi.ss.usermodel.*;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;

import java.io.File;
import java.io.FileOutputStream;
import java.util.*;

public class ExportDataScreen extends BorderPane {

    private final AppNavigator nav;

    private final CustomerDao customerDao = new CustomerDao();
    private final TransactionDao txnDao = new TransactionDao();

    public ExportDataScreen(AppNavigator nav) {
        this.nav = nav;

        setPadding(new Insets(12));
        setTop(buildTop());
        setCenter(buildCenter());
    }

    private HBox buildTop() {
        Label title = new Label("Export Data");
        title.setStyle("-fx-font-size: 16px; -fx-font-weight: bold;");

        Button backBtn = new Button("← Back");
        backBtn.setOnAction(e -> nav.goBack());

        HBox bar = new HBox(10, backBtn, title);
        bar.setPadding(new Insets(0, 0, 12, 0));
        return bar;
    }

    private VBox buildCenter() {
        Label help = new Label(
                "Exports one Excel file with:\n" +
                "• Sheet 1: Customers (click name → opens customer sheet)\n" +
                "• Sheet 2: All Transactions (VOID excluded)\n" +
                "• One sheet per customer: their transactions\n"
        );

        Button exportExcelBtn = new Button("Export All to Excel (Customers + Transactions)");
        exportExcelBtn.setMaxWidth(Double.MAX_VALUE);
        exportExcelBtn.setOnAction(e -> exportAllToExcel());

        VBox box = new VBox(12, help, exportExcelBtn);
        box.setPadding(new Insets(10));
        box.setStyle("-fx-border-color: #bbb; -fx-border-radius: 8; -fx-background-radius: 8;");
        return box;
    }

    private void exportAllToExcel() {
        FileChooser fc = new FileChooser();
        fc.setTitle("Save Excel Export");
        fc.getExtensionFilters().add(new FileChooser.ExtensionFilter("Excel", "*.xlsx"));
        fc.setInitialFileName("accounting-export.xlsx");

        File file = fc.showSaveDialog(getScene() == null ? null : getScene().getWindow());
        if (file == null) return;

        try {
            List<Customer> customers = customerDao.listAll();
            List<Transaction> allTxns = txnDao.listAllPosted(); // VOID excluded ✅

            // group txns by customer
            Map<Long, List<Transaction>> byCustomer = new HashMap<>();
            for (Transaction t : allTxns) {
                byCustomer.computeIfAbsent(t.getCustomerId(), k -> new ArrayList<>()).add(t);
            }

            try (Workbook wb = new XSSFWorkbook()) {
                CreationHelper helper = wb.getCreationHelper();

                // Styles
                CellStyle headerStyle = wb.createCellStyle();
                Font headerFont = wb.createFont();
                headerFont.setBold(true);
                headerStyle.setFont(headerFont);

                CellStyle moneyStyle = wb.createCellStyle();
                DataFormat fmt = wb.createDataFormat();
                moneyStyle.setDataFormat(fmt.getFormat("₹#,##0.00"));

                // -------------------------
                // Sheet 1: Customers
                // -------------------------
                Sheet customersSheet = wb.createSheet("Customers");

                Row h = customersSheet.createRow(0);
                String[] custHeaders = {"customer_id", "name", "phone", "address", "notes", "is_active"};
                for (int i = 0; i < custHeaders.length; i++) {
                    org.apache.poi.ss.usermodel.Cell cell = h.createCell(i);
                    cell.setCellValue(custHeaders[i]);
                    cell.setCellStyle(headerStyle);
                }

                // Create customer sheets first so we know sheet names
                Map<Long, String> customerSheetName = new HashMap<>();
                for (Customer c : customers) {
                    String sheetName = safeSheetName("CUST_" + c.getCustomerId() + "_" + nz(c.getName()));
                    sheetName = uniqueSheetName(wb, sheetName);

                    customerSheetName.put(c.getCustomerId(), sheetName);

                    Sheet s = wb.createSheet(sheetName);
                    writeCustomerTxnSheet(
                            helper,
                            headerStyle,
                            moneyStyle,
                            s,
                            customersSheet.getSheetName(),
                            c,
                            byCustomer.getOrDefault(c.getCustomerId(), List.of())
                    );
                }

                // Fill customers rows + hyperlink on name
                int r = 1;
                for (Customer c : customers) {
                    Row row = customersSheet.createRow(r);

                    row.createCell(0).setCellValue(c.getCustomerId());

                    org.apache.poi.ss.usermodel.Cell nameCell = row.createCell(1);
                    nameCell.setCellValue(nz(c.getName()));

                    // hyperlink to that customer's sheet A1
                    String targetSheet = customerSheetName.get(c.getCustomerId());
                    if (targetSheet != null) {
                    	org.apache.poi.ss.usermodel.Hyperlink link = helper.createHyperlink(HyperlinkType.DOCUMENT);
                        link.setAddress("'" + targetSheet + "'!A1");
                        nameCell.setHyperlink(link);
                    }

                    row.createCell(2).setCellValue(nz(c.getPhone()));
                    row.createCell(3).setCellValue(nz(c.getAddress()));
                    row.createCell(4).setCellValue(nz(c.getNotes()));
                    row.createCell(5).setCellValue(c.getIsActive() == 1 ? "ACTIVE" : "INACTIVE");

                    r++;
                }

                for (int i = 0; i < custHeaders.length; i++) customersSheet.autoSizeColumn(i);

                // -------------------------
                // Sheet 2: All Transactions
                // -------------------------
                Sheet allSheet = wb.createSheet("All_Transactions");

                Row th = allSheet.createRow(0);
                String[] txnHeaders = {"txn_id", "customer_id", "txn_date", "txn_type", "amount_paise", "amount_rupees", "reference", "notes"};
                for (int i = 0; i < txnHeaders.length; i++) {
                    org.apache.poi.ss.usermodel.Cell cell = th.createCell(i);
                    cell.setCellValue(txnHeaders[i]);
                    cell.setCellStyle(headerStyle);
                }

                int tr = 1;
                for (Transaction t : allTxns) {
                    Row row = allSheet.createRow(tr++);
                    row.createCell(0).setCellValue(t.getTxnId());
                    row.createCell(1).setCellValue(t.getCustomerId());
                    row.createCell(2).setCellValue(nz(t.getTxnDate()));
                    row.createCell(3).setCellValue(nz(t.getTxnType()));
                    row.createCell(4).setCellValue(t.getAmountPaise());

                    // rupees value with Excel currency formatting
                    org.apache.poi.ss.usermodel.Cell ru = row.createCell(5);
                    ru.setCellValue(t.getAmountPaise() / 100.0);
                    ru.setCellStyle(moneyStyle);

                    row.createCell(6).setCellValue(nz(t.getReference()));
                    row.createCell(7).setCellValue(nz(t.getNotes()));
                }

                for (int i = 0; i < txnHeaders.length; i++) allSheet.autoSizeColumn(i);

                // Write file
                try (FileOutputStream fos = new FileOutputStream(file)) {
                    wb.write(fos);
                }
            }

            new Alert(Alert.AlertType.INFORMATION, "Exported Excel:\n" + file.getAbsolutePath()).showAndWait();

        } catch (Exception ex) {
            ex.printStackTrace();
            new Alert(Alert.AlertType.ERROR, "Export failed:\n\n" + ex.getMessage()).showAndWait();
        }
    }

    private void writeCustomerTxnSheet(CreationHelper helper,
                                      CellStyle headerStyle,
                                      CellStyle moneyStyle,
                                      Sheet sheet,
                                      String customersSheetName,
                                      Customer customer,
                                      List<Transaction> txns) {

        // A1: Title
        Row r0 = sheet.createRow(0);
        org.apache.poi.ss.usermodel.Cell title = r0.createCell(0);
        title.setCellValue("Customer: " + nz(customer.getName()) + " (" + nz(customer.getPhone()) + ")");

        // A2: back link
        Row r1 = sheet.createRow(1);
        org.apache.poi.ss.usermodel.Cell back = r1.createCell(0);
        back.setCellValue("← Back to Customers");
        org.apache.poi.ss.usermodel.Hyperlink backLink = helper.createHyperlink(HyperlinkType.DOCUMENT);
        backLink.setAddress("'" + customersSheetName + "'!A1");
        back.setHyperlink(backLink);

        // Header row
        Row h = sheet.createRow(3);
        String[] cols = {"txn_id", "txn_date", "txn_type", "amount_paise", "amount_rupees", "reference", "notes"};
        for (int i = 0; i < cols.length; i++) {
            org.apache.poi.ss.usermodel.Cell cell = h.createCell(i);
            cell.setCellValue(cols[i]);
            cell.setCellStyle(headerStyle);
        }

        int rr = 4;
        for (Transaction t : txns) {
            Row row = sheet.createRow(rr++);
            row.createCell(0).setCellValue(t.getTxnId());
            row.createCell(1).setCellValue(nz(t.getTxnDate()));
            row.createCell(2).setCellValue(nz(t.getTxnType()));
            row.createCell(3).setCellValue(t.getAmountPaise());

            org.apache.poi.ss.usermodel.Cell ru = row.createCell(4);
            ru.setCellValue(t.getAmountPaise() / 100.0);
            ru.setCellStyle(moneyStyle);

            row.createCell(5).setCellValue(nz(t.getReference()));
            row.createCell(6).setCellValue(nz(t.getNotes()));
        }

        for (int i = 0; i < cols.length; i++) sheet.autoSizeColumn(i);
        sheet.createFreezePane(0, 4);

    }

    private String nz(String s) {
        return (s == null) ? "" : s;
    }

    private String safeSheetName(String name) {
        String x = (name == null ? "Sheet" : name.trim());
        x = x.replaceAll("[\\\\/?*\\[\\]:]", "_");
        x = x.replaceAll("\\s+", " ").trim();
        if (x.length() > 31) x = x.substring(0, 31);
        if (x.isEmpty()) x = "Sheet";
        return x;
    }

    private String uniqueSheetName(Workbook wb, String base) {
        String name = base;
        int i = 1;
        while (wb.getSheet(name) != null) {
            String suffix = "_" + i;
            int max = 31 - suffix.length();
            String trimmed = base.length() > max ? base.substring(0, max) : base;
            name = trimmed + suffix;
            i++;
        }
        return name;
    }
}

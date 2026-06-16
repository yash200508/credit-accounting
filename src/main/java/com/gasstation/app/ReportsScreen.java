package com.gasstation.app;

import com.gasstation.app.dao.CustomerDao;
import com.gasstation.app.dao.TransactionDao;
import com.gasstation.app.model.Customer;
import com.gasstation.app.model.CustomerKpi;
import com.gasstation.app.service.LedgerExportService;
import com.gasstation.app.service.CustomerKpiService;
import com.gasstation.app.service.ReportSummaryService;
import com.gasstation.app.util.CsvUtil;
import com.gasstation.app.util.MoneyUtil;

import javafx.geometry.Insets;
import javafx.scene.control.*;
import javafx.scene.layout.*;
import javafx.stage.FileChooser;
import com.gasstation.app.service.LedgerPdfExportService;
import java.nio.file.Path;
import javafx.stage.DirectoryChooser;
import com.gasstation.app.service.LedgerExcelExportService;


import java.io.File;
import java.sql.SQLException;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.stream.Collectors;

public class ReportsScreen extends BorderPane {

    private final CustomerDao customerDao = new CustomerDao();
    private final TransactionDao txnDao = new TransactionDao();
    private final CustomerKpiService kpiService = new CustomerKpiService();
    private final ReportSummaryService reportSummaryService = new ReportSummaryService(customerDao, txnDao);

    private final DatePicker from = new DatePicker(LocalDate.now().withDayOfMonth(1));
    private final DatePicker to = new DatePicker(LocalDate.now());

    private final Label collectionsLbl = new Label("₹0.00");
    private final Label creditGivenLbl = new Label("₹0.00");
    private final Label netLbl = new Label("₹0.00");

    private final TextArea notes = new TextArea();

    private final Label statusLbl = new Label("Ready");

    public ReportsScreen(AppNavigator nav) {
        setPadding(new Insets(10));
        setTop(buildTop());
        setCenter(buildCenter());
        setBottom(buildBottom());
        refresh();
    }

    private Pane buildTop() {
        Label title = new Label("Reports");
        title.setStyle("-fx-font-size: 16px; -fx-font-weight: bold;");

        Button refreshBtn = new Button("Refresh");
        refreshBtn.setOnAction(e -> refresh());

        Button exportReceivablesBtn = new Button("Export Receivables CSV");
        exportReceivablesBtn.setOnAction(e -> exportReceivablesCsv());

        Button exportPeriodBtn = new Button("Export Period Summary CSV");
        exportPeriodBtn.setOnAction(e -> exportPeriodCsv());

        Region spacer = new Region();
        HBox.setHgrow(spacer, Priority.ALWAYS);
       
        Button exportAllPdfsFolderBtn = new Button("Export All PDFs (Folder)");
        exportAllPdfsFolderBtn.setOnAction(e -> exportAllPdfsFolder());

        Button exportAllPdfsSingleBtn = new Button("Export All PDFs (Single)");
        exportAllPdfsSingleBtn.setOnAction(e -> exportAllPdfsSingle());
        
        Button exportExcelBtn = new Button("Export Full Ledger (Excel)");
        exportExcelBtn.setOnAction(e -> exportFullLedgerExcel());

        Button exportAccountingXlsxBtn = new Button("Export Accounting Excel (.xlsx)");
        exportAccountingXlsxBtn.setOnAction(e -> exportAccountingXlsx());

        HBox bar = new HBox(10, title, spacer,
                new Label("From:"), from,
                new Label("To:"), to,
                refreshBtn,
                exportReceivablesBtn,
                exportPeriodBtn,
                exportExcelBtn,
                exportAllPdfsFolderBtn,
                exportAllPdfsSingleBtn,
                exportAccountingXlsxBtn);
        
        bar.setPadding(new Insets(0, 0, 10, 0));
        return bar;
    }

    private Pane buildCenter() {
        collectionsLbl.setStyle("-fx-font-size: 15px; -fx-font-weight: bold;");
        creditGivenLbl.setStyle("-fx-font-size: 15px; -fx-font-weight: bold;");
        netLbl.setStyle("-fx-font-size: 15px; -fx-font-weight: bold;");

        HBox cards = new HBox(10,
                card("Collections (Credits)", collectionsLbl),
                card("Credit Given (Debits)", creditGivenLbl),
                card("Net (Credits - Debits)", netLbl)
        );

        notes.setEditable(false);
        notes.setWrapText(true);
        notes.setPrefRowCount(10);
        notes.setText("Exports:\n- Receivables CSV: current total due + overdue + risk by customer.\n- Period Summary CSV: debits/credits between From-To per customer plus totals.\n\nTip: Use this for monthly closing, accountant, or to see collection performance.");

        VBox root = new VBox(12, cards, new Label("Notes"), notes);
        return root;
    }

    private VBox card(String title, Label value) {
        Label t = new Label(title);
        t.setStyle("-fx-text-fill: #333;");
        VBox v = new VBox(4, t, value);
        v.setPadding(new Insets(10));
        v.setStyle("-fx-border-color: #bbb; -fx-border-radius: 8; -fx-background-radius: 8;");
        v.setMaxWidth(Double.MAX_VALUE);
        HBox.setHgrow(v, Priority.ALWAYS);
        return v;
    }

    private Pane buildBottom() {
        statusLbl.setStyle("-fx-text-fill: #666;");
        HBox bar = new HBox(statusLbl);
        bar.setPadding(new Insets(10, 0, 0, 0));
        return bar;
    }

    private void refresh() {
        try {
            String f = from.getValue().toString();
            String t = to.getValue().toString();
            ReportSummaryService.PeriodSummary summary = reportSummaryService.buildPeriodSummary(from.getValue(), to.getValue());
            collectionsLbl.setText(MoneyUtil.formatMoney(summary.totalCreditsPaise()));
            creditGivenLbl.setText(MoneyUtil.formatMoney(summary.totalDebitsPaise()));
            netLbl.setText(MoneyUtil.formatMoney(summary.netPaise()));
            statusLbl.setText("Loaded period: " + f + " to " + t);
        } catch (SQLException e) {
            statusLbl.setText("Error: " + e.getMessage());
            new Alert(Alert.AlertType.ERROR, "Failed to load report\n\n" + e.getMessage()).showAndWait();
        }
    }

    private void exportReceivablesCsv() {
        FileChooser fc = new FileChooser();
        fc.setTitle("Save Receivables CSV");
        fc.getExtensionFilters().add(new FileChooser.ExtensionFilter("CSV", "*.csv"));
        fc.setInitialFileName("receivables-" + LocalDate.now() + ".csv");
        File file = fc.showSaveDialog(getScene() == null ? null : getScene().getWindow());
        if (file == null) return;

        try {
            List<Customer> customers = customerDao.listAll();
            List<CustomerKpi> kpis = kpiService.buildForCustomers(customers)
                    .stream()
                    .sorted(Comparator.comparingLong(CustomerKpi::getTotalDuePaise).reversed())
                    .collect(Collectors.toList());

            List<List<String>> rows = new ArrayList<>();
            for (CustomerKpi k : kpis) {
                Customer c = k.getCustomer();
                rows.add(List.of(
                        Long.toString(c.getCustomerId()),
                        c.getName(),
                        c.getPhone(),
                        c.getIsActive() == 1 ? "ACTIVE" : "INACTIVE",
                        MoneyUtil.formatMoney(k.getPrincipalBalancePaise()),
                        MoneyUtil.formatMoney(k.getInterestAccruedPaise()),
                        MoneyUtil.formatMoney(k.getTotalDuePaise()),
                        MoneyUtil.formatMoney(k.getOverdueAmountPaise()),
                        Integer.toString(k.getMaxDaysOverdue()),
                        k.getRiskTag(),
                        Long.toString(c.getCreditLimitPaise()),
                        Integer.toString(c.getDueDays()),
                        Integer.toString(c.getGraceDays())
                ));
            }

            CsvUtil.write(file.toPath(),
                    List.of("customer_id", "name", "phone", "status", "principal", "interest", "total_due", "overdue", "days_past_due", "risk", "credit_limit_paise", "due_days", "grace_days"),
                    rows);
            new Alert(Alert.AlertType.INFORMATION, "Exported: " + file.getAbsolutePath()).showAndWait();
        } catch (Exception e) {
            new Alert(Alert.AlertType.ERROR, "Export failed\n\n" + e.getMessage()).showAndWait();
        }
    }
    
    private void exportAccountingXlsx() {
        FileChooser fc = new FileChooser();
        fc.setTitle("Save Accounting Excel (.xlsx)");
        fc.getExtensionFilters().add(new FileChooser.ExtensionFilter("Excel", "*.xlsx"));
        fc.setInitialFileName("accounting-export-" + from.getValue() + "_to_" + to.getValue() + ".xlsx");

        File file = fc.showSaveDialog(getScene() == null ? null : getScene().getWindow());
        if (file == null) return;

        try {
            LedgerExcelExportService svc = new LedgerExcelExportService();
            svc.exportAccountingXlsx(
                    file.toPath(),
                    from.getValue(),
                    to.getValue()
            );

            new Alert(Alert.AlertType.INFORMATION,
                    "Exported Excel:\n" + file.getAbsolutePath() +
                    "\n\nSheet1: Customers (click name to open ledger sheet)\nSheet2: All_Transactions\n+ one sheet per customer")
                    .showAndWait();

        } catch (Exception ex) {
            ex.printStackTrace();
            new Alert(Alert.AlertType.ERROR, "Export failed\n\n" + ex.getMessage()).showAndWait();
        }
    }

    
    private void exportAllPdfsFolder() {
        DirectoryChooser dc = new DirectoryChooser();
        dc.setTitle("Choose Folder to Save PDFs");
        File folder = dc.showDialog(getScene() == null ? null : getScene().getWindow());
        if (folder == null) return;

        try {
            LedgerPdfExportService svc = new LedgerPdfExportService();
            svc.exportAllCustomersToFolder(
                    folder.toPath(),
                    from.getValue(),
                    to.getValue()
            );
            new Alert(Alert.AlertType.INFORMATION, "Exported PDFs to:\n" + folder.getAbsolutePath()).showAndWait();
        } catch (Exception ex) {
            ex.printStackTrace();
            new Alert(Alert.AlertType.ERROR, "Export failed\n\n" + ex.getMessage()).showAndWait();
        }
    }

    private void exportAllPdfsSingle() {
        FileChooser fc = new FileChooser();
        fc.setTitle("Save Single Combined PDF");
        fc.getExtensionFilters().add(new FileChooser.ExtensionFilter("PDF", "*.pdf"));
        fc.setInitialFileName("all-ledgers-" + from.getValue() + "_to_" + to.getValue() + ".pdf");

        File file = fc.showSaveDialog(getScene() == null ? null : getScene().getWindow());
        if (file == null) return;

        try {
            LedgerPdfExportService svc = new LedgerPdfExportService();

            // PdfStatementService writes into a directory, so split path:
            Path outDir = file.toPath().getParent();
            String baseName = file.getName().replaceAll("\\.pdf$", "");

            Path pdf = svc.exportAllCustomersSinglePdf(
                    outDir,
                    baseName,
                    from.getValue(),
                    to.getValue()
            );

            new Alert(Alert.AlertType.INFORMATION, "Exported:\n" + pdf.toAbsolutePath()).showAndWait();
        } catch (Exception ex) {
            ex.printStackTrace();
            new Alert(Alert.AlertType.ERROR, "Export failed\n\n" + ex.getMessage()).showAndWait();
        }
    }

    private void exportFullLedgerExcel() {
        FileChooser fc = new FileChooser();
        fc.setTitle("Save Full Ledger Excel");
        fc.getExtensionFilters().add(
                new FileChooser.ExtensionFilter("Excel Files", "*.xlsx")
        );
        fc.setInitialFileName("full-ledger-" + LocalDate.now() + ".xlsx");

        File file = fc.showSaveDialog(
                getScene() == null ? null : getScene().getWindow()
        );
        if (file == null) return;

        try {
            LedgerExportService service = new LedgerExportService();
            service.exportAllCustomersWithLedgers(file.toPath());

            new Alert(
                    Alert.AlertType.INFORMATION,
                    "Excel exported successfully:\n" + file.getAbsolutePath()
            ).showAndWait();

        } catch (Exception ex) {
            ex.printStackTrace();
            new Alert(
                    Alert.AlertType.ERROR,
                    "Export failed\n\n" + ex.getMessage()
            ).showAndWait();
        }
    }


    private void exportPeriodCsv() {
        FileChooser fc = new FileChooser();
        fc.setTitle("Save Period Summary CSV");
        fc.getExtensionFilters().add(new FileChooser.ExtensionFilter("CSV", "*.csv"));
        fc.setInitialFileName("period-summary-" + from.getValue() + "_to_" + to.getValue() + ".csv");
        File file = fc.showSaveDialog(getScene() == null ? null : getScene().getWindow());
        if (file == null) return;

        try {
            String f = from.getValue().toString();
            String t = to.getValue().toString();
            ReportSummaryService.PeriodSummary summary = reportSummaryService.buildPeriodSummary(from.getValue(), to.getValue());
            List<List<String>> rows = new ArrayList<>();

            for (ReportSummaryService.PeriodCustomerSummary row : summary.rows()) {
                rows.add(List.of(
                        Long.toString(row.customerId()),
                        row.name(),
                        row.phone(),
                        MoneyUtil.formatMoney(row.debitsPaise()),
                        MoneyUtil.formatMoney(row.creditsPaise()),
                        MoneyUtil.formatMoney(row.netPaise())
                ));
            }

            // Totals row
            rows.add(List.of("", "TOTAL", "", MoneyUtil.formatMoney(summary.totalDebitsPaise()), MoneyUtil.formatMoney(summary.totalCreditsPaise()), MoneyUtil.formatMoney(summary.netPaise())));

            CsvUtil.write(file.toPath(),
                    List.of("customer_id", "name", "phone", "debits", "credits", "net"),
                    rows);
            new Alert(Alert.AlertType.INFORMATION, "Exported: " + file.getAbsolutePath()).showAndWait();
        } catch (Exception e) {
            new Alert(Alert.AlertType.ERROR, "Export failed\n\n" + e.getMessage()).showAndWait();
        }
    }
}

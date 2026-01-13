package com.gasstation.app;

import com.gasstation.app.dao.TransactionDao;
import com.gasstation.app.dao.CustomerDao;
import com.gasstation.app.dao.AuditDao;
import com.gasstation.app.dao.SettingsDao;
import com.gasstation.app.model.Customer;
import com.gasstation.app.model.Transaction;
import com.gasstation.app.service.InterestCalculator;
import com.gasstation.app.service.CustomerKpiService;
import com.gasstation.app.service.PdfStatementService;
import javafx.collections.FXCollections;
import javafx.collections.ObservableList;
import javafx.geometry.Insets;
import javafx.scene.control.*;
import javafx.scene.control.cell.PropertyValueFactory;
import javafx.scene.layout.*;
import javafx.scene.Scene;
import javafx.stage.Stage;
import javafx.print.PrinterJob;
import javafx.scene.control.Button;
import javafx.scene.layout.HBox;
import javafx.print.PageLayout;

import javafx.scene.text.Text;
import javafx.scene.text.Font;
import javafx.scene.text.TextFlow;
import javafx.scene.Group;
import javafx.scene.shape.Rectangle;
import javafx.stage.Window;

import java.time.LocalDate;
import java.nio.file.Path;
import java.util.List;

public class LedgerScreen extends BorderPane {

    private final Customer customer;
    private final CustomerDao customerDao = new CustomerDao();
    private final TransactionDao txnDao = new TransactionDao();
    private final AuditDao auditDao = new AuditDao();
    private final SettingsDao settingsDao = new SettingsDao();
    private final InterestCalculator calc = new InterestCalculator();
    private final PdfStatementService pdfService = new PdfStatementService();

    private final ObservableList<Transaction> txnData = FXCollections.observableArrayList();
    private final TableView<Transaction> table = new TableView<>(txnData);


    private final Label interestLbl = new Label("-");
    private final Label interestTitleLbl = new Label("Interest:");
    private final Label totalLbl = new Label("-");
    private final DatePicker fromPicker = new DatePicker(LocalDate.now().withDayOfMonth(1));
    private final DatePicker toPicker = new DatePicker(LocalDate.now());
    private final Button calcBtn = new Button("Calculate");
    private final Button todayBtn = new Button("Today");
    private final Label openingLbl = new Label("-");
    private final Label closingLbl = new Label("-");
    private final Label debitsLbl = new Label("-");
    private final Label creditsLbl = new Label("-");
  

    private final AppNavigator nav;

    public LedgerScreen(AppNavigator nav, Customer customer) {
        this.nav = nav;
        this.customer = customer;

        setPadding(new Insets(12));

        setTop(buildHeader());
        setCenter(buildTable());
        setRight(buildEntryPanel());

        refresh();
    }

    private Pane buildHeader() {
        Label title = new Label("Ledger: " + customer.getName() + "  |  " + customer.getPhone());
        title.setStyle("-fx-font-size: 16px; -fx-font-weight: bold;");

        Button backBtn = new Button("← Back");
        backBtn.setOnAction(e -> nav.showCustomers());

        todayBtn.setOnAction(e -> {
            fromPicker.setValue(LocalDate.now().withDayOfMonth(1));
            toPicker.setValue(LocalDate.now());
            refresh();
        });

        calcBtn.setOnAction(e -> refresh());

        HBox topRow = new HBox(10, backBtn, title);

        HBox rangeRow = new HBox(10,
                new Label("From:"), fromPicker,
                new Label("To:"), toPicker,
                calcBtn, todayBtn
        );
        rangeRow.setPadding(new Insets(8, 0, 0, 0));
        Button printRangeBtn = new Button("Print Selected Range");
        Button printFullBtn = new Button("Print Full Statement");

        Button pdfRangeBtn = new Button("Export PDF (Range)");
        Button pdfFullBtn = new Button("Export PDF (Full)");

        printRangeBtn.setOnAction(e ->
                printStatement(fromPicker.getValue(), toPicker.getValue())
        );

        printFullBtn.setOnAction(e ->
                printStatement(null, null)
        );

        pdfRangeBtn.setOnAction(e -> exportPdf(fromPicker.getValue(), toPicker.getValue()));
        pdfFullBtn.setOnAction(e -> exportPdf(null, null));

        HBox printRow = new HBox(10, printRangeBtn, printFullBtn, pdfRangeBtn, pdfFullBtn);
        VBox box = new VBox(8, topRow, rangeRow, printRow, buildSummaryBar());
        box.setPadding(new Insets(0, 0, 12, 0));
        return box;
    }



    private Pane buildSummaryBar() {
        GridPane gp = new GridPane();
        gp.setHgap(14);
        gp.setVgap(6);

        gp.add(new Label("Opening Principal:"), 0, 0);
        gp.add(openingLbl, 1, 0);

        gp.add(new Label("Debits in Range:"), 2, 0);
        gp.add(debitsLbl, 3, 0);

        gp.add(new Label("Credits in Range:"), 4, 0);
        gp.add(creditsLbl, 5, 0);

        gp.add(new Label("Closing Principal:"), 6, 0);
        gp.add(closingLbl, 7, 0);

        gp.add(interestTitleLbl, 0, 1);
        gp.add(interestLbl, 1, 1);

        gp.add(new Label("Total Due:"), 2, 1);
        gp.add(totalLbl, 3, 1);

        return gp;
    }



    private Pane buildTable() {
        TableColumn<Transaction, String> dateCol = new TableColumn<>("Date");
        dateCol.setCellValueFactory(new PropertyValueFactory<>("txnDate"));
        dateCol.setPrefWidth(120);

        TableColumn<Transaction, String> typeCol = new TableColumn<>("Type");
        typeCol.setCellValueFactory(new PropertyValueFactory<>("txnType"));
        typeCol.setPrefWidth(90);

        TableColumn<Transaction, Long> amtCol = new TableColumn<>("Amount");
        amtCol.setCellValueFactory(new PropertyValueFactory<>("amountPaise"));
        amtCol.setPrefWidth(140);
        amtCol.setCellFactory(col -> new TableCell<>() {
            @Override protected void updateItem(Long item, boolean empty) {
                super.updateItem(item, empty);
                setText(empty || item == null ? "" : formatMoney(item));
            }
        });
        TableColumn<Transaction, Long> balCol = new TableColumn<>("Balance");
        balCol.setCellValueFactory(new PropertyValueFactory<>("runningBalancePaise"));
        balCol.setPrefWidth(150);
        balCol.setCellFactory(col -> new TableCell<>() {
            @Override
            protected void updateItem(Long item, boolean empty) {
                super.updateItem(item, empty);
                setText(empty || item == null ? "" : formatMoney(item));
            }
        });


        TableColumn<Transaction, String> refCol = new TableColumn<>("Ref");
        refCol.setCellValueFactory(new PropertyValueFactory<>("reference"));
        refCol.setPrefWidth(120);

        TableColumn<Transaction, String> notesCol = new TableColumn<>("Notes");
        notesCol.setCellValueFactory(new PropertyValueFactory<>("notes"));
        notesCol.setPrefWidth(260);

        table.getColumns().clear();
        table.getColumns().add(dateCol);
        table.getColumns().add(typeCol);
        table.getColumns().add(amtCol);
        table.getColumns().add(balCol);
        table.getColumns().add(refCol);
        table.getColumns().add(notesCol);
        table.getColumns().clear();
        table.getColumns().add(dateCol);
        table.getColumns().add(typeCol);
        table.getColumns().add(amtCol);
        table.getColumns().add(balCol);
        table.getColumns().add(refCol);
        table.getColumns().add(notesCol);

        table.setColumnResizePolicy(TableView.CONSTRAINED_RESIZE_POLICY);
        table.setPlaceholder(new Label("No transactions yet."));

        // Right-click actions (safer than delete)
        table.setRowFactory(tv -> {
            TableRow<Transaction> row = new TableRow<>();
            MenuItem voidItem = new MenuItem("Void transaction");
            voidItem.setOnAction(e -> {
                Transaction t = row.getItem();
                if (t == null) return;
                TextInputDialog d = new TextInputDialog();
                d.setTitle("Void Transaction");
                d.setHeaderText("Voiding txn #" + t.getTxnId() + " (" + t.getTxnType() + " " + formatMoney(t.getAmountPaise()) + ")");
                d.setContentText("Reason:");
                d.showAndWait().ifPresent(reason -> {
                    try {
                        txnDao.voidTransaction(t.getTxnId(), reason);
                        auditDao.log("VOID_TXN", "transaction", t.getTxnId(), reason);
                        refresh();
                    } catch (Exception ex) {
                        alert("Failed", ex.getMessage());
                    }
                });
            });
            ContextMenu m = new ContextMenu(voidItem);
            row.contextMenuProperty().bind(
                    javafx.beans.binding.Bindings.when(row.emptyProperty())
                            .then((ContextMenu) null)
                            .otherwise(m)
            );
            return row;
        });

        VBox box = new VBox(8, new Label("Transactions"), table);
        VBox.setVgrow(table, Priority.ALWAYS);
        return box;
    }

    private Pane buildEntryPanel() {
        Label title = new Label("Add Entry");
        title.setStyle("-fx-font-weight: bold; -fx-font-size: 14px;");

        DatePicker datePicker = new DatePicker(LocalDate.now());
        TextField amountField = new TextField();
        amountField.setPromptText("Amount (₹)");

        TextField refField = new TextField();
        refField.setPromptText("Reference (optional)");

        TextArea notesField = new TextArea();
        notesField.setPromptText("Notes (optional)");
        notesField.setPrefRowCount(3);

        Button addDebitBtn = new Button("+ Add DEBIT (Credit Taken)");
        Button addCreditBtn = new Button("- Add CREDIT (Payment)");

        addDebitBtn.setMaxWidth(Double.MAX_VALUE);
        addCreditBtn.setMaxWidth(Double.MAX_VALUE);

        addDebitBtn.setOnAction(e ->
                addTxn(datePicker.getValue(), "DEBIT", amountField.getText(), refField.getText(), notesField.getText())
        );

        addCreditBtn.setOnAction(e ->
                addTxn(datePicker.getValue(), "CREDIT", amountField.getText(), refField.getText(), notesField.getText())
        );

        VBox panel = new VBox(10,
                title,
                new Label("Date"), datePicker,
                new Label("Amount"), amountField,
                refField,
                notesField,
                addDebitBtn,
                addCreditBtn
        );
        panel.setPadding(new Insets(12));
        panel.setPrefWidth(300);
        panel.setStyle("-fx-border-color: #444; -fx-border-radius: 6; -fx-padding: 12;");
        return panel;
    }

    private void addTxn(LocalDate date, String type, String amountText, String ref, String notes) {
        long paise = parseRupeesToPaise(amountText);
        if (paise <= 0) {
            alert("Invalid amount", "Please enter a valid amount in rupees.");
            return;
        }

        // Credit limit enforcement (business safety)
        if ("DEBIT".equalsIgnoreCase(type)) {
            try {
                Customer fresh = customerDao.findByPhone(customer.getPhone());
                long limit = (fresh == null) ? 0 : fresh.getCreditLimitPaise();
                if (limit > 0) {
                    // Current total due (principal+interest as of today)
                    CustomerKpiService kpiService = new CustomerKpiService();
                    var kpi = kpiService.buildForCustomer(fresh);
                    long projected = kpi.getTotalDuePaise() + paise;
                    if (projected > limit) {
                        Alert a = new Alert(Alert.AlertType.CONFIRMATION);
                        a.setTitle("Credit Limit Exceeded");
                        a.setHeaderText("This debit will exceed the customer's credit limit.");
                        a.setContentText(
                                "Limit: " + formatMoney(limit) + "\n" +
                                "Current total due: " + formatMoney(kpi.getTotalDuePaise()) + "\n" +
                                "New debit: " + formatMoney(paise) + "\n" +
                                "Projected: " + formatMoney(projected) + "\n\n" +
                                "Proceed anyway?");
                        if (a.showAndWait().orElse(ButtonType.CANCEL) != ButtonType.OK) {
                            return;
                        }
                        auditDao.log("OVERRIDE_LIMIT", "customer", fresh.getCustomerId(),
                                "Projected " + projected + " > limit " + limit);
                    }
                }
            } catch (Exception ignored) {
                // Don't block posting if something goes wrong
            }
        }

        try {
            Transaction t = new Transaction();
            t.setCustomerId(customer.getCustomerId());
            t.setTxnDate(date.toString());
            t.setTxnType(type);
            t.setAmountPaise(paise);
            t.setReference(ref);
            t.setNotes(notes);

            txnDao.insert(t);
            auditDao.log("ADD_TXN", "transaction", null,
                    "cust=" + customer.getCustomerId() + ", type=" + type + ", amount=" + paise);
            refresh();
        } catch (Exception ex) {
            ex.printStackTrace();
            alert("Failed", ex.getMessage());
        }
    }

    private void refresh() {
        try {
            List<Transaction> list = txnDao.listByCustomer(customer.getCustomerId());
            long balance = 0;

            for (Transaction t : list) {
                if ("DEBIT".equalsIgnoreCase(t.getTxnType())) {
                    balance += t.getAmountPaise();
                } else if ("CREDIT".equalsIgnoreCase(t.getTxnType())) {
                    balance -= t.getAmountPaise();
                    if (balance < 0) balance = 0;
                }
                t.setRunningBalancePaise(balance);
            }

            txnData.setAll(list);


            double rate = settingsDao.getDouble(CustomerKpiService.KEY_RATE, InterestCalculator.ANNUAL_RATE);
            interestTitleLbl.setText(String.format("Interest (%.2f%%):", rate * 100.0));

            var summary = calc.computeStatementWithRate(
                    list,
                    fromPicker.getValue(),
                    toPicker.getValue().plusDays(1),   // calculator uses [from, to)
                    rate
            );

            openingLbl.setText(formatMoney(summary.openingPrincipalPaise));
            debitsLbl.setText(formatMoney(summary.debitsInRangePaise));
            creditsLbl.setText(formatMoney(summary.creditsInRangePaise));
            closingLbl.setText(formatMoney(summary.closingPrincipalPaise));
            interestLbl.setText(formatMoney(summary.interestPaise));
            totalLbl.setText(formatMoney(summary.totalDuePaise));


        } catch (Exception ex) {
            ex.printStackTrace();
            alert("Load failed", ex.getMessage());
        }
    }

    private void printStatement(LocalDate from, LocalDate to) {
        try {
            String statementText = buildStatementText(from, to);

            // 6) UI preview + print
            TextArea ta = new TextArea(statementText);
            ta.setEditable(false);
            ta.setWrapText(false);
            ta.setStyle("-fx-font-family: monospace;");

            Button printBtn = new Button("Print");
            Button closeBtn = new Button("Close");

            HBox btnRow = new HBox(10, printBtn, closeBtn);
            btnRow.setPadding(new Insets(10));
            btnRow.setStyle("-fx-alignment: center-right;");

            BorderPane root = new BorderPane(ta);
            root.setBottom(btnRow);

            Stage stage = new Stage();
            stage.setTitle("Statement Preview");
            stage.setScene(new Scene(root, 800, 600));

            printBtn.setOnAction(e -> {
                boolean ok = printStatementText(statementText);
                if (ok) alert("Printed", "Sent to printer successfully.");
            });

            closeBtn.setOnAction(e -> stage.close());

            stage.show();

        } catch (Exception ex) {
            ex.printStackTrace();
            alert("Print failed", ex.getMessage());
        }
    }

    private void exportPdf(LocalDate from, LocalDate to) {
        try {
            String statementText = buildStatementText(from, to);
            Path outDir = Path.of(System.getProperty("user.home"), ".credit-accounting", "exports");
            Path pdf = pdfService.exportStatementText(customer.getName(), statementText, outDir);
            alert("PDF Created", "Saved: " + pdf.toAbsolutePath());
        } catch (Exception ex) {
            ex.printStackTrace();
            alert("PDF Export failed", ex.getMessage());
        }
    }

    /**
     * Builds the statement text for a date range (or full history when from/to are null).
     * This text is used by both Print Preview and PDF Export.
     */
    private String buildStatementText(LocalDate from, LocalDate to) throws Exception {
        List<Transaction> all = txnDao.listByCustomer(customer.getCustomerId());

        // Resolve dates
        LocalDate resolvedFrom;
        LocalDate resolvedTo;

        if (from == null || to == null) {
            resolvedFrom = all.isEmpty() ? LocalDate.now() : LocalDate.parse(all.get(0).getTxnDate());
            resolvedTo = LocalDate.now();
        } else {
            resolvedFrom = from;
            resolvedTo = to;
        }

        final LocalDate fromDate = resolvedFrom;
        final LocalDate toDate = resolvedTo;

        // Filter for statement lines
        List<Transaction> filtered = all.stream()
                .filter(t -> {
                    LocalDate d = LocalDate.parse(t.getTxnDate());
                    return !d.isBefore(fromDate) && !d.isAfter(toDate);
                })
                .toList();

        // Interest summary (calculator expects [from, to))
        double rate = settingsDao.getDouble(CustomerKpiService.KEY_RATE, InterestCalculator.ANNUAL_RATE);
        var summary = calc.computeStatementWithRate(all, fromDate, toDate.plusDays(1), rate);

        StringBuilder sb = new StringBuilder();
        sb.append("Surya Lakshmi Fuels Point CREDIT STATEMENT\n");
        sb.append("----------------------------------\n");
        sb.append("Customer: ").append(customer.getName()).append("\n");
        sb.append("Phone   : ").append(customer.getPhone()).append("\n");
        sb.append("Period  : ").append(fromDate).append(" to ").append(toDate).append("\n\n");

        sb.append(String.format("Opening Principal : %s\n", formatMoney(summary.openingPrincipalPaise)));
        sb.append(String.format("Debits in Period  : %s\n", formatMoney(summary.debitsInRangePaise)));
        sb.append(String.format("Credits in Period : %s\n", formatMoney(summary.creditsInRangePaise)));
        sb.append(String.format("Closing Principal : %s\n", formatMoney(summary.closingPrincipalPaise)));
        sb.append(String.format("Interest (%.2f%%)    : %s\n", rate * 100.0, formatMoney(summary.interestPaise)));
        sb.append(String.format("TOTAL DUE         : %s\n\n", formatMoney(summary.totalDuePaise)));

        sb.append("DATE       TYPE     AMOUNT        BALANCE       REF\n");
        sb.append("------------------------------------------------------\n");

        long running = summary.openingPrincipalPaise;
        for (Transaction t : filtered) {
            if ("DEBIT".equalsIgnoreCase(t.getTxnType())) running += t.getAmountPaise();
            else running -= t.getAmountPaise();

            sb.append(String.format(
                    "%-10s %-7s %-12s %-12s %s\n",
                    t.getTxnDate(),
                    t.getTxnType(),
                    formatMoney(t.getAmountPaise()),
                    formatMoney(Math.max(0, running)),
                    t.getReference() == null ? "" : t.getReference()
            ));
        }

        return sb.toString();
    }


    private boolean printStatementText(String content) {
        PrinterJob job = PrinterJob.createPrinterJob();
        if (job == null) {
            alert("Print Error", "No printer found.");
            return false;
        }

        Window owner = (getScene() != null) ? getScene().getWindow() : null;

        boolean proceed = (owner != null) ? job.showPrintDialog(owner) : job.showPrintDialog(null);
        if (!proceed) return false;

        PageLayout layout = job.getJobSettings().getPageLayout();
        double printableW = layout.getPrintableWidth();
        double printableH = layout.getPrintableHeight();

        // Build printable text (NOT TextArea, because TextArea is virtualized)
        Text text = new Text(content);
        text.setFont(Font.font("Monospaced", 11));

        TextFlow flow = new TextFlow(text);
        flow.setPrefWidth(printableW); // helps wrapping
        flow.setLineSpacing(0);

        // Force CSS/layout pass (important for correct height)
        flow.applyCss();
        flow.layout();

        // Auto-scale to fit width (only scale down, never scale up)
        double contentW = flow.getBoundsInLocal().getWidth();
        double scale = (contentW <= 0) ? 1.0 : Math.min(1.0, printableW / contentW);

        flow.setScaleX(scale);
        flow.setScaleY(scale);

        // After scaling, recompute size
        flow.applyCss();
        flow.layout();

        // We paginate by shifting Y
        double scaledContentH = flow.getBoundsInLocal().getHeight() * scale;

        // Clip size in unscaled coordinates (because node is scaled)
        Rectangle clip = new Rectangle(printableW / scale, printableH / scale);
        flow.setClip(clip);

        Group root = new Group(flow);

        // Print each page
        int pageIndex = 0;
        while (pageIndex * printableH < scaledContentH) {
            double y = -pageIndex * (printableH / scale);
            flow.setTranslateY(y);

            boolean ok = job.printPage(layout, root);
            if (!ok) {
                job.endJob();
                return false;
            }

            pageIndex++;
        }

        job.endJob();
        return true;
    }

    private void alert(String title, String msg) {
        Alert a = new Alert(Alert.AlertType.INFORMATION);
        a.setTitle(title);
        a.setHeaderText(title);
        a.setContentText(msg);
        a.showAndWait();
    }

    private long parseRupeesToPaise(String text) {
        if (text == null) return 0;
        String t = text.trim();
        if (t.isEmpty()) return 0;

        try {
            if (t.contains(".")) {
                String[] parts = t.split("\\.");
                String ru = parts[0].replaceAll("[^0-9]", "");
                String pa = parts.length > 1 ? parts[1].replaceAll("[^0-9]", "") : "0";
                if (pa.length() == 1) pa = pa + "0";
                if (pa.length() > 2) pa = pa.substring(0, 2);
                if (pa.isEmpty()) pa = "00";
                return Long.parseLong(ru) * 100L + Long.parseLong(pa);
            } else {
                String ru = t.replaceAll("[^0-9]", "");
                return Long.parseLong(ru) * 100L;
            }
        } catch (Exception e) {
            return 0;
        }
    }

  

    private String formatMoney(long paise) {
        long rupees = paise / 100;
        long p = Math.abs(paise % 100);
        return "₹" + rupees + "." + (p < 10 ? "0" + p : p);
    }
}

package com.gasstation.app;

import com.gasstation.app.dao.CustomerDao;
import com.gasstation.app.model.Customer;
import com.gasstation.app.model.CustomerKpi;
import com.gasstation.app.service.CustomerKpiService;
import com.gasstation.app.util.MoneyUtil;
import javafx.beans.property.SimpleStringProperty;
import javafx.collections.FXCollections;
import javafx.geometry.Insets;
import javafx.scene.Node;
import javafx.scene.control.*;
import javafx.scene.layout.*;

import java.sql.SQLException;
import java.time.LocalDate;
import java.util.Comparator;
import java.util.List;
import java.util.stream.Collectors;

/**
 * Owner Dashboard:
 * - Who owes me the most?
 * - Who is overdue?
 * - Who is paying regularly vs risky?
 */
public class DashboardScreen extends BorderPane {

    private final AppNavigator nav;
    private final CustomerDao customerDao = new CustomerDao();
    private final CustomerKpiService kpiService = new CustomerKpiService();

    private final Label statusLbl = new Label("Ready");

    private final TableView<CustomerKpi> topDebtorsTable = new TableView<>();
    private final TableView<CustomerKpi> overdueTable = new TableView<>();

    private final TableView<CustomerKpi> greenTable = new TableView<>();
    private final TableView<CustomerKpi> yellowTable = new TableView<>();
    private final TableView<CustomerKpi> redTable = new TableView<>();

    private final Label totalReceivablesLbl = new Label("₹0.00");
    private final Label totalOverdueLbl = new Label("₹0.00");
    private final Label interestMonthLbl = new Label("₹0.00");

    public DashboardScreen(AppNavigator nav) {
        this.nav = nav;
        setPadding(new Insets(10));

        setTop(buildTopBar());
        setCenter(buildContent());
        setBottom(buildFooter());

        refresh();
    }

    private Pane buildTopBar() {
        Label title = new Label("Owner Dashboard");
        title.setStyle("-fx-font-size: 16px; -fx-font-weight: bold;");

        Button refreshBtn = new Button("Refresh");
        refreshBtn.setOnAction(e -> refresh());

        Region spacer = new Region();
        HBox.setHgrow(spacer, Priority.ALWAYS);

        HBox bar = new HBox(10, title, spacer, refreshBtn);
        bar.setPadding(new Insets(0, 0, 10, 0));
        return bar;
    }

    private Node buildContent() {
        VBox cards = new VBox(10, buildSummaryCards());

        configureTable(topDebtorsTable);
        configureTable(overdueTable);
        configureTable(greenTable);
        configureTable(yellowTable);
        configureTable(redTable);

        Label a = new Label("Who owes me the most? (Top 10)");
        a.setStyle("-fx-font-weight: bold;");
        Label b = new Label("Who is overdue?");
        b.setStyle("-fx-font-weight: bold;");
        Label c = new Label("Who is paying regularly vs risky?");
        c.setStyle("-fx-font-weight: bold;");

        VBox left = new VBox(8, a, topDebtorsTable);
        VBox right = new VBox(8, b, overdueTable);

        VBox.setVgrow(topDebtorsTable, Priority.ALWAYS);
        VBox.setVgrow(overdueTable, Priority.ALWAYS);


        HBox top = new HBox(12, left, right);

        HBox.setHgrow(left, Priority.ALWAYS);
        HBox.setHgrow(right, Priority.ALWAYS);

        // If you need top to expand vertically inside a VBox parent:
        VBox.setVgrow(top, Priority.ALWAYS);


        TabPane riskTabs = new TabPane();
        riskTabs.getTabs().add(tab("Green (Regular)", greenTable));
        riskTabs.getTabs().add(tab("Yellow (Watch)", yellowTable));
        riskTabs.getTabs().add(tab("Red (Risky)", redTable));
        riskTabs.setTabClosingPolicy(TabPane.TabClosingPolicy.UNAVAILABLE);

        VBox bottom = new VBox(8, c, riskTabs);
        VBox.setVgrow(riskTabs, Priority.ALWAYS);

        VBox root = new VBox(12, cards, top, bottom);
        VBox.setVgrow(top, Priority.ALWAYS);
        VBox.setVgrow(bottom, Priority.ALWAYS);

        return root;
    }

    private Pane buildSummaryCards() {
        totalReceivablesLbl.setStyle("-fx-font-size: 15px; -fx-font-weight: bold;");
        totalOverdueLbl.setStyle("-fx-font-size: 15px; -fx-font-weight: bold;");
        interestMonthLbl.setStyle("-fx-font-size: 15px; -fx-font-weight: bold;");

        VBox c1 = card("Total Receivables", totalReceivablesLbl);
        VBox c2 = card("Total Overdue", totalOverdueLbl);
        VBox c3 = card("Interest Accrued", interestMonthLbl);

        HBox row = new HBox(10, c1, c2, c3);
        row.setPadding(new Insets(0, 0, 5, 0));
        HBox.setHgrow(c1, Priority.ALWAYS);
        HBox.setHgrow(c2, Priority.ALWAYS);
        HBox.setHgrow(c3, Priority.ALWAYS);
        c1.setMaxWidth(Double.MAX_VALUE);
        c2.setMaxWidth(Double.MAX_VALUE);
        c3.setMaxWidth(Double.MAX_VALUE);
        return row;
    }

    private VBox card(String title, Label value) {
        Label t = new Label(title);
        t.setStyle("-fx-text-fill: #333;");
        VBox v = new VBox(4, t, value);
        v.setPadding(new Insets(10));
        v.setStyle("-fx-border-color: #bbb; -fx-border-radius: 8; -fx-background-radius: 8;");
        return v;
    }

    private Tab tab(String title, TableView<CustomerKpi> table) {
        Tab t = new Tab(title);
        t.setContent(table);
        return t;
    }

    private Pane buildFooter() {
        statusLbl.setStyle("-fx-text-fill: #666;");
        HBox bar = new HBox(statusLbl);
        bar.setPadding(new Insets(10, 0, 0, 0));
        return bar;
    }

    private void configureTable(TableView<CustomerKpi> table) {
        table.setColumnResizePolicy(TableView.CONSTRAINED_RESIZE_POLICY);
        table.getColumns().clear();

        TableColumn<CustomerKpi, String> name = new TableColumn<>("Customer");
        name.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().getCustomer().getName()));

        TableColumn<CustomerKpi, String> total = new TableColumn<>("Total Due");
        total.setCellValueFactory(d -> new SimpleStringProperty(MoneyUtil.formatMoney(d.getValue().getTotalDuePaise())));

        TableColumn<CustomerKpi, String> overdue = new TableColumn<>("Overdue");
        overdue.setCellValueFactory(d -> new SimpleStringProperty(MoneyUtil.formatMoney(d.getValue().getOverdueAmountPaise())));

        TableColumn<CustomerKpi, String> days = new TableColumn<>("Days Overdue");
        days.setCellValueFactory(d -> new SimpleStringProperty(Integer.toString(d.getValue().getMaxDaysOverdue())));

        TableColumn<CustomerKpi, String> lastPay = new TableColumn<>("Last Payment");
        lastPay.setCellValueFactory(d -> {
            LocalDate lp = d.getValue().getLastPaymentDate();
            return new SimpleStringProperty(lp == null ? "-" : lp.toString());
        });

        TableColumn<CustomerKpi, String> risk = new TableColumn<>("Risk");
        risk.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().getRiskTag()));

        table.getColumns().setAll(List.of(name, total, overdue, days, lastPay, risk));

        table.setRowFactory(tv -> {
            TableRow<CustomerKpi> row = new TableRow<>();
            row.setOnMouseClicked(e -> {
                if (e.getClickCount() == 2 && !row.isEmpty()) {
                    Customer c = row.getItem().getCustomer();
                    nav.showLedger(c);
                }
            });
            return row;
        });
    }


    private void refresh() {
        try {
            statusLbl.setText("Loading...");
            List<Customer> customers = customerDao.listAll();
            List<CustomerKpi> kpis = kpiService.buildForCustomers(customers);

            // Summary cards
            long receivables = kpis.stream().mapToLong(CustomerKpi::getTotalDuePaise).sum();
            long overdueTotal = kpis.stream().mapToLong(CustomerKpi::getOverdueAmountPaise).sum();

            long interestMonth = kpis.stream().mapToLong(CustomerKpi::getInterestAccruedPaise).sum();
            totalReceivablesLbl.setText(MoneyUtil.formatMoney(receivables));
            totalOverdueLbl.setText(MoneyUtil.formatMoney(overdueTotal));
            interestMonthLbl.setText(MoneyUtil.formatMoney(interestMonth));

            // Top debtors
            List<CustomerKpi> topDebtors = kpis.stream()
                    .sorted(Comparator.comparingLong(CustomerKpi::getTotalDuePaise).reversed())
                    .limit(10)
                    .collect(Collectors.toList());
            topDebtorsTable.setItems(FXCollections.observableArrayList(topDebtors));

            // Overdue list
            List<CustomerKpi> overdueList = kpis.stream()
                    .filter(k -> k.getOverdueAmountPaise() > 0)
                    .sorted(Comparator.comparingInt(CustomerKpi::getMaxDaysOverdue).reversed())
                    .collect(Collectors.toList());
            overdueTable.setItems(FXCollections.observableArrayList(overdueList));

            // Risk buckets
            greenTable.setItems(FXCollections.observableArrayList(kpis.stream().filter(k -> "GREEN".equals(k.getRiskTag())).collect(Collectors.toList())));
            yellowTable.setItems(FXCollections.observableArrayList(kpis.stream().filter(k -> "YELLOW".equals(k.getRiskTag())).collect(Collectors.toList())));
            redTable.setItems(FXCollections.observableArrayList(kpis.stream().filter(k -> "RED".equals(k.getRiskTag())).collect(Collectors.toList())));

            statusLbl.setText("Loaded " + kpis.size() + " customers");
        } catch (SQLException e) {
            statusLbl.setText("Error: " + e.getMessage());
            new Alert(Alert.AlertType.ERROR, "Failed to load dashboard\n\n" + e.getMessage()).showAndWait();
        }
    }
}

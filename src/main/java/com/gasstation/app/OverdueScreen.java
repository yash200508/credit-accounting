package com.gasstation.app;

import com.gasstation.app.dao.CustomerDao;
import com.gasstation.app.model.Customer;
import com.gasstation.app.model.CustomerKpi;
import com.gasstation.app.service.CustomerKpiService;
import com.gasstation.app.service.OverduePolicyService;
import com.gasstation.app.util.CsvUtil;
import com.gasstation.app.util.MoneyUtil;
import javafx.beans.property.SimpleStringProperty;
import javafx.collections.FXCollections;
import javafx.collections.ObservableList;
import javafx.geometry.Insets;
import javafx.scene.control.*;
import javafx.scene.layout.*;
import javafx.stage.FileChooser;

import java.sql.SQLException;
import java.util.*;
import java.util.stream.Collectors;
import java.util.Comparator;
import java.util.List;

public class OverdueScreen extends BorderPane {

    private final AppNavigator nav;

    private final CustomerDao customerDao = new CustomerDao();
    private final CustomerKpiService kpiService = new CustomerKpiService();
    private final OverduePolicyService overduePolicy = new OverduePolicyService();

    private final ComboBox<String> bucketFilter = new ComboBox<>();
    private final CheckBox activeOnly = new CheckBox("Active only");

    private final Label statusLbl = new Label(" ");
    private final TableView<CustomerKpi> table = new TableView<>();

    private final ObservableList<CustomerKpi> data = FXCollections.observableArrayList();

    public OverdueScreen(AppNavigator nav) {
        this.nav = nav;
        setPadding(new Insets(10));

        setTop(buildTopBar());
        setCenter(buildTable());
        setBottom(buildBottomBar());

        refresh();
    }

    private Pane buildTopBar() {
        Label title = new Label("Overdue & Aging");
        title.setStyle("-fx-font-size: 16px; -fx-font-weight: bold;");

        bucketFilter.getItems().setAll(overduePolicy.bucketLabels());
        bucketFilter.setValue("All");
        bucketFilter.setOnAction(e -> applyFilters());

        activeOnly.setSelected(true);
        activeOnly.setOnAction(e -> applyFilters());

        Button refreshBtn = new Button("Refresh");
        refreshBtn.setOnAction(e -> refresh());

        Button exportBtn = new Button("Export CSV");
        exportBtn.setOnAction(e -> exportCsv());

        Region spacer = new Region();
        HBox.setHgrow(spacer, Priority.ALWAYS);

        HBox row = new HBox(10, title, spacer,
                new Label("Bucket:"), bucketFilter,
                activeOnly,
                refreshBtn,
                exportBtn);
        row.setPadding(new Insets(0, 0, 10, 0));
        return row;
    }

    private Pane buildTable() {
        table.setColumnResizePolicy(TableView.CONSTRAINED_RESIZE_POLICY);
        VBox box = new VBox(table);
        VBox.setVgrow(table, Priority.ALWAYS);
        TableColumn<CustomerKpi, String> name = new TableColumn<>("Customer");
        name.setCellValueFactory(d -> new SimpleStringProperty(
                d.getValue().getCustomer() == null ? "" : d.getValue().getCustomer().getName()
        ));

        TableColumn<CustomerKpi, String> overdue = new TableColumn<>("Overdue Amount");
        overdue.setCellValueFactory(d -> new SimpleStringProperty(
                MoneyUtil.formatMoney(d.getValue().getOverdueAmountPaise())
        ));

        TableColumn<CustomerKpi, String> days = new TableColumn<>("Max Days Overdue");
        days.setCellValueFactory(d -> new SimpleStringProperty(
                Integer.toString(d.getValue().getMaxDaysOverdue())
        ));

        TableColumn<CustomerKpi, String> total = new TableColumn<>("Total Due");
        total.setCellValueFactory(d -> new SimpleStringProperty(
                MoneyUtil.formatMoney(d.getValue().getTotalDuePaise())
        ));

        TableColumn<CustomerKpi, String> risk = new TableColumn<>("Risk");
        risk.setCellValueFactory(d -> new SimpleStringProperty(
                d.getValue().getRiskTag() == null ? "" : d.getValue().getRiskTag()
        ));

        table.getColumns().setAll(List.of(name, overdue, days, total, risk));
        table.setItems(data);

        // double click -> ledger
        table.setRowFactory(tv -> {
            TableRow<CustomerKpi> row = new TableRow<>();
            row.setOnMouseClicked(e -> {
                if (e.getClickCount() == 2 && !row.isEmpty()) {
                    CustomerKpi k = row.getItem();
                    if (k != null && k.getCustomer() != null) {
                        nav.showLedger(k.getCustomer());
                    }
                }
            });
            return row;
        });

        return box;
    }



    private Pane buildBottomBar() {
        HBox box = new HBox(statusLbl);
        box.setPadding(new Insets(10, 0, 0, 0));
        return box;
    }

    private void refresh() {
        try {
            statusLbl.setText("Loading...");
            List<Customer> customers = customerDao.listAll();

            List<CustomerKpi> kpis = kpiService.buildForCustomers(customers)
                    .stream()
                    .filter(k -> k.getOverdueAmountPaise() > 0)
                    .sorted(Comparator.comparingInt(CustomerKpi::getMaxDaysOverdue).reversed())
                    .collect(Collectors.toList());

            data.setAll(kpis);
            applyFilters();
            statusLbl.setText("Loaded " + data.size() + " overdue customer(s)");
        } catch (SQLException e) {
            statusLbl.setText("Error: " + e.getMessage());
            new Alert(Alert.AlertType.ERROR, "Failed to load overdue list\n\n" + e.getMessage()).showAndWait();
        }
    }

    private void applyFilters() {
        String b = bucketFilter.getValue();
        boolean onlyActive = activeOnly.isSelected();

        List<CustomerKpi> filtered = new ArrayList<>(data);

        if (onlyActive) {
            filtered = filtered.stream()
                    .filter(k -> k.getCustomer() != null && k.getCustomer().getIsActive() == 1)
                    .collect(Collectors.toList());
        }

        if (b != null && !"All".equals(b)) {
            filtered = filtered.stream()
                    .filter(k -> overduePolicy.bucketOf(k.getMaxDaysOverdue()).equals(b))
                    .collect(Collectors.toList());
        }

        table.setItems(FXCollections.observableArrayList(filtered));
    }

    private void exportCsv() {
        FileChooser fc = new FileChooser();
        fc.setTitle("Save Overdue CSV");
        fc.getExtensionFilters().add(new FileChooser.ExtensionFilter("CSV", "*.csv"));
        var f = fc.showSaveDialog(getScene() == null ? null : getScene().getWindow());
        if (f == null) return;

        try {
            List<CustomerKpi> items = table.getItems();
            List<List<String>> out = new ArrayList<>();

            for (CustomerKpi k : items) {
                Customer c = k.getCustomer();
                if (c == null) continue;
                out.add(List.of(
                        Long.toString(c.getCustomerId()),
                        c.getName(),
                        c.getPhone(),
                        MoneyUtil.formatMoney(k.getOverdueAmountPaise()),
                        Integer.toString(k.getMaxDaysOverdue()),
                        overduePolicy.bucketOf(k.getMaxDaysOverdue()),
                        MoneyUtil.formatMoney(k.getTotalDuePaise()),
                        k.getRiskTag() == null ? "" : k.getRiskTag()
                ));
            }

            CsvUtil.write(f.toPath(),
                    List.of("customer_id", "name", "phone", "overdue", "days_past_due", "bucket", "total_due", "risk"),
                    out);

            new Alert(Alert.AlertType.INFORMATION, "Exported: " + f.getAbsolutePath()).showAndWait();
        } catch (Exception e) {
            new Alert(Alert.AlertType.ERROR, "CSV export failed\n\n" + e.getMessage()).showAndWait();
        }
    }
}

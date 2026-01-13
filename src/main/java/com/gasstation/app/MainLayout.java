package com.gasstation.app;

import com.gasstation.app.model.Customer;
import javafx.geometry.Insets;
import javafx.scene.Node;
import javafx.scene.control.Button;
import javafx.scene.control.Label;
import javafx.scene.control.Separator;
import javafx.scene.layout.BorderPane;
import javafx.scene.layout.HBox;
import javafx.scene.layout.Pane;
import javafx.scene.layout.Priority;
import javafx.scene.layout.StackPane;
import javafx.scene.layout.VBox;

public class MainLayout extends BorderPane {

    private final AppNavigator nav;

    // Sidebar buttons
    private final Button dashboardBtn = new Button("Dashboard");
    private final Button customersBtn = new Button("Customers");
    private final Button overdueBtn = new Button("Overdue");
    private final Button remindersBtn = new Button("Reminders");
    private final Button reportsBtn = new Button("Reports");

    private final Button importBtn = new Button("Import");
    private final Button exportBtn = new Button("Export Data");
    private final Button settingsBtn = new Button("Settings");

    private final Label headerTitle = new Label("Dashboard");

    public MainLayout(AppNavigator nav) {
        this.nav = nav;

        setPadding(new Insets(10));
        setLeft(buildSidebar());
        setTop(buildHeader());

        // Default screen
        showDashboardScreen();
    }

    private Pane buildSidebar() {
        dashboardBtn.setMaxWidth(Double.MAX_VALUE);
        customersBtn.setMaxWidth(Double.MAX_VALUE);
        overdueBtn.setMaxWidth(Double.MAX_VALUE);
        remindersBtn.setMaxWidth(Double.MAX_VALUE);
        reportsBtn.setMaxWidth(Double.MAX_VALUE);
        importBtn.setMaxWidth(Double.MAX_VALUE);
        exportBtn.setMaxWidth(Double.MAX_VALUE);
        settingsBtn.setMaxWidth(Double.MAX_VALUE);

        dashboardBtn.setOnAction(e -> showDashboardScreen());

        customersBtn.setOnAction(e -> showCustomersScreen());

        overdueBtn.setOnAction(e -> {
            headerTitle.setText("Overdue");
            setCenter(new OverdueScreen(nav));
        });

        remindersBtn.setOnAction(e -> {
            headerTitle.setText("Reminders");
            setCenter(new RemindersScreen(nav));
        });

        reportsBtn.setOnAction(e -> {
            headerTitle.setText("Reports");
            setCenter(new ReportsScreen(nav));
        });

        importBtn.setOnAction(e -> showImportHubScreen());

        exportBtn.setOnAction(e -> showExportScreen());

        settingsBtn.setOnAction(e -> showSettingsHubScreen());

        VBox box = new VBox(
                10,
                dashboardBtn,
                customersBtn,
                overdueBtn,
                remindersBtn,
                reportsBtn,
                new Separator(),
                importBtn,
                exportBtn,
                settingsBtn
        );

        box.setPadding(new Insets(10));
        box.setPrefWidth(170);
        box.setStyle("-fx-border-color: #444; -fx-border-radius: 6; -fx-padding: 12;");
        return box;
    }

    private Pane buildHeader() {
        headerTitle.setStyle("-fx-font-size: 16px; -fx-font-weight: bold;");

        HBox top = new HBox(10, headerTitle);
        HBox.setHgrow(headerTitle, Priority.ALWAYS);

        top.setPadding(new Insets(6, 0, 12, 12));
        return top;
    }

    @SuppressWarnings("unused")
    private Node comingSoon(String msg) {
        Label l = new Label(msg);
        l.setStyle("-fx-font-size: 14px;");
        StackPane p = new StackPane(l);
        p.setPadding(new Insets(20));
        return p;
    }

    // ✅ Navigator uses these
    public void showDashboardScreen() {
        headerTitle.setText("Dashboard");
        setCenter(new DashboardScreen(nav));
    }

    public void showCustomersScreen() {
        headerTitle.setText("Customers");
        setCenter(new CustomerScreen(nav));
    }

    public void showLedgerScreen(Customer customer) {
        headerTitle.setText("Ledger - " + customer.getName());
        setCenter(new LedgerScreen(nav, customer));
    }

    // Old name kept: transaction import
    public void showImportExcelScreen() {
        headerTitle.setText("Import Excel");
        setCenter(new ImportExcelScreen(nav));
    }

    public void showImportHubScreen() {
        headerTitle.setText("Import");
        setCenter(new ImportHubScreen(nav));
    }

    public void showCustomerImportScreen() {
        headerTitle.setText("Import Customers");
        setCenter(new CustomerImportScreen(nav));
    }

    public void showSettingsHubScreen() {
        headerTitle.setText("Settings");
        setCenter(new SettingsHubScreen(nav));
    }

    public void showInterestSettingsScreen() {
        headerTitle.setText("Interest Settings");
        setCenter(new InterestSettingsScreen(nav));
    }

    public void showReminderSettingsScreen() {
        headerTitle.setText("Reminder Settings");
        setCenter(new ReminderSettingsScreen(nav));
    }

    public void showOverdueSettingsScreen() {
        headerTitle.setText("Overdue Settings");
        setCenter(new OverdueSettingsScreen(nav));
    }

    

    public void showExportScreen() {
        headerTitle.setText("Export Data");
        setCenter(new ExportDataScreen(nav));
    }
}

package com.gasstation.app;

import com.gasstation.app.model.Customer;
import javafx.scene.Scene;
import javafx.stage.Stage;

public class AppNavigator {

    private final Stage stage;
    private final MainLayout mainLayout;

    public AppNavigator(Stage stage) {
        this.stage = stage;
        this.mainLayout = new MainLayout(this);
    }

    public void start() {
        stage.setScene(new Scene(mainLayout, 1100, 700));
        stage.show();
    }

    public void showDashboard() {
        mainLayout.showDashboardScreen();
    }

    public void showCustomers() {
        mainLayout.showCustomersScreen();
    }

    public void showLedger(Customer customer) {
        mainLayout.showLedgerScreen(customer);
    }

    // Backward compatible name: open Import hub
    public void showImportExcel() {
        mainLayout.showImportHubScreen();
    }

    public void showImportHub() {
        mainLayout.showImportHubScreen();
    }

    public void showCustomerImport() {
        mainLayout.showCustomerImportScreen();
    }

    public void showTransactionImport() {
        mainLayout.showImportExcelScreen();
    }

    public void showSettings() {
        mainLayout.showSettingsHubScreen();
    }

    public void showInterestSettings() {
        mainLayout.showInterestSettingsScreen();
    }

    public void showReminderSettings() {
        mainLayout.showReminderSettingsScreen();
    }

    public void showOverdueSettings() {
        mainLayout.showOverdueSettingsScreen();
    }

    public void showExport() {
        mainLayout.showExportScreen();
    }

    // ✅ Back behavior: go to Customers
    public void goBack() {
        showCustomers();
    }
}

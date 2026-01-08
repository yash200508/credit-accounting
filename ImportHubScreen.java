package com.gasstation.app;

import javafx.geometry.Insets;
import javafx.scene.control.Button;
import javafx.scene.control.Label;
import javafx.scene.control.Separator;
import javafx.scene.layout.BorderPane;
import javafx.scene.layout.HBox;
import javafx.scene.layout.Priority;
import javafx.scene.layout.Region;
import javafx.scene.layout.VBox;

/**
 * Hub screen: choose what you want to import.
 */
public class ImportHubScreen extends BorderPane {

    private final AppNavigator nav;

    public ImportHubScreen(AppNavigator nav) {
        this.nav = nav;
        setPadding(new Insets(12));

        Label title = new Label("Import");
        title.setStyle("-fx-font-size: 16px; -fx-font-weight: bold;");

        Button back = new Button("← Back");
        back.setOnAction(e -> nav.goBack());

        Region spacer = new Region();
        HBox.setHgrow(spacer, Priority.ALWAYS);
        HBox top = new HBox(10, back, title, spacer);
        top.setPadding(new Insets(0, 0, 10, 0));

        Button importCustomers = new Button("Import Customers (Excel)");
        importCustomers.setMaxWidth(Double.MAX_VALUE);
        importCustomers.setOnAction(e -> nav.showCustomerImport());

        Button importTransactions = new Button("Import Transactions (Google Form Excel)");
        importTransactions.setMaxWidth(Double.MAX_VALUE);
        importTransactions.setOnAction(e -> nav.showTransactionImport());

        Label help = new Label(
                "Choose what you want to import.\n\n" +
                "• Customers import: Name + Phone (required), other fields optional.\n" +
                "• Transactions import: Phone must already exist in Customers."
        );
        help.setStyle("-fx-text-fill: #666;");

        VBox center = new VBox(12,
                help,
                new Separator(),
                importCustomers,
                importTransactions
        );
        center.setPadding(new Insets(10, 0, 0, 0));

        setTop(top);
        setCenter(center);
    }
}

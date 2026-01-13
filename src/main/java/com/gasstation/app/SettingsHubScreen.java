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

public class SettingsHubScreen extends BorderPane {

    private final AppNavigator nav;

    public SettingsHubScreen(AppNavigator nav) {
        this.nav = nav;
        setPadding(new Insets(12));

        Label title = new Label("Settings");
        title.setStyle("-fx-font-size: 16px; -fx-font-weight: bold;");

        Button back = new Button("← Back");
        back.setOnAction(e -> nav.goBack());

        Region spacer = new Region();
        HBox.setHgrow(spacer, Priority.ALWAYS);

        HBox top = new HBox(10, back, title, spacer);
        top.setPadding(new Insets(0, 0, 10, 0));

        Button interestBtn = new Button("Interest Settings");
        interestBtn.setMaxWidth(Double.MAX_VALUE);
        interestBtn.setOnAction(e -> nav.showInterestSettings());

        Button reminderBtn = new Button("Reminder & Alert Settings");
        reminderBtn.setMaxWidth(Double.MAX_VALUE);
        reminderBtn.setOnAction(e -> nav.showReminderSettings());

        Button overdueBtn = new Button("Overdue Bucket Settings");
        overdueBtn.setMaxWidth(Double.MAX_VALUE);
        overdueBtn.setOnAction(e -> nav.showOverdueSettings());

        Label help = new Label(
                "These settings control interest, reminder messages,\n" +
                "and overdue bucket grouping used in reports."
        );
        help.setStyle("-fx-text-fill: #666;");

        VBox center = new VBox(12,
                help,
                new Separator(),
                interestBtn,
                reminderBtn,
                overdueBtn
        );
        center.setPadding(new Insets(10, 0, 0, 0));

        setTop(top);
        setCenter(center);
    }
}

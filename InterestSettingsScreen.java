package com.gasstation.app;

import com.gasstation.app.dao.SettingsDao;
import javafx.geometry.Insets;
import javafx.scene.control.*;
import javafx.scene.layout.*;

import java.sql.SQLException;

public class InterestSettingsScreen extends BorderPane {

    private final SettingsDao settingsDao = new SettingsDao();

    private final TextField annualRateField = new TextField();
    private final TextField graceDaysField = new TextField();

    private final Label statusLbl = new Label(" ");

    public InterestSettingsScreen(AppNavigator nav) {
        setPadding(new Insets(12));

        // Top bar with back button
        Button backBtn = new Button("← Back to Settings");
        backBtn.setOnAction(e -> nav.showSettings());

        Label title = new Label("Interest Settings");
        title.setStyle("-fx-font-size: 16px; -fx-font-weight: bold;");

        HBox top = new HBox(10, backBtn, title);
        top.setPadding(new Insets(0, 0, 10, 0));
        setTop(new VBox(top, new Separator()));

        // Form
        GridPane form = new GridPane();
        form.setHgap(10);
        form.setVgap(10);
        form.setPadding(new Insets(10, 0, 0, 0));

        form.add(new Label("Annual Interest Rate (%)"), 0, 0);
        form.add(annualRateField, 1, 0);

        form.add(new Label("Interest Grace Days (global)"), 0, 1);
        form.add(graceDaysField, 1, 1);

        Button saveBtn = new Button("Save");
        saveBtn.setOnAction(e -> save());

        Button reloadBtn = new Button("Reload");
        reloadBtn.setOnAction(e -> load());

        HBox actions = new HBox(10, saveBtn, reloadBtn);

        VBox center = new VBox(12,
                new Label("Note: If per-customer graceDays is used elsewhere, keep this for interest-only calculations."),
                form,
                actions,
                statusLbl
        );

        setCenter(center);

        load();
    }

    private void load() {
        try {
            annualRateField.setText(settingsDao.get("interest_annual_rate", "0"));
            graceDaysField.setText(settingsDao.get("interest_grace_days", "0"));
            statusLbl.setText("Loaded");
        } catch (SQLException e) {
            statusLbl.setText("Error: " + e.getMessage());
            new Alert(Alert.AlertType.ERROR, "Failed to load interest settings\n\n" + e.getMessage()).showAndWait();
        }
    }

    private void save() {
        try {
            double rate = Double.parseDouble(annualRateField.getText().trim());
            int grace = Integer.parseInt(graceDaysField.getText().trim());

            if (rate < 0 || rate > 1000) throw new NumberFormatException("Rate must be between 0 and 1000");
            if (grace < 0 || grace > 3650) throw new NumberFormatException("Grace days must be 0..3650");

            settingsDao.set("interest_annual_rate", Double.toString(rate));
            settingsDao.set("interest_grace_days", Integer.toString(grace));

            statusLbl.setText("Saved ✅");
        } catch (NumberFormatException nfe) {
            new Alert(Alert.AlertType.WARNING, "Invalid input\n\n" + nfe.getMessage()).showAndWait();
        } catch (SQLException e) {
            statusLbl.setText("Error: " + e.getMessage());
            new Alert(Alert.AlertType.ERROR, "Failed to save interest settings\n\n" + e.getMessage()).showAndWait();
        }
    }
}

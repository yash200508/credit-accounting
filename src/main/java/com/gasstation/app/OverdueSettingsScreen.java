package com.gasstation.app;

import com.gasstation.app.dao.SettingsDao;
import com.gasstation.app.service.OverduePolicyService;
import javafx.geometry.Insets;
import javafx.scene.control.*;
import javafx.scene.layout.*;

import java.sql.SQLException;

public class OverdueSettingsScreen extends BorderPane {

    private final AppNavigator nav;
    private final SettingsDao settingsDao = new SettingsDao();

    private final TextField b1Field = new TextField();
    private final TextField b2Field = new TextField();
    private final TextField b3Field = new TextField();
    private final TextField b4Field = new TextField();

    private final Label statusLbl = new Label(" ");

    public OverdueSettingsScreen(AppNavigator nav) {
        this.nav = nav;
        setPadding(new Insets(12));

        Button backBtn = new Button("← Back to Settings");
        backBtn.setOnAction(e -> nav.showSettings());

        Label title = new Label("Overdue Bucket Settings");
        title.setStyle("-fx-font-size: 16px; -fx-font-weight: bold;");

        HBox top = new HBox(10, backBtn, title);
        top.setPadding(new Insets(0, 0, 10, 0));
        setTop(new VBox(top, new Separator()));

        GridPane form = new GridPane();
        form.setHgap(10);
        form.setVgap(10);
        form.setPadding(new Insets(10, 0, 0, 0));

        form.add(new Label("Bucket 1 max days (0 - X)"), 0, 0);
        form.add(b1Field, 1, 0);

        form.add(new Label("Bucket 2 max days (X+1 - Y)"), 0, 1);
        form.add(b2Field, 1, 1);

        form.add(new Label("Bucket 3 max days (Y+1 - Z)"), 0, 2);
        form.add(b3Field, 1, 2);

        form.add(new Label("Bucket 4 max days (Z+1 - W)"), 0, 3);
        form.add(b4Field, 1, 3);

        Label help = new Label("Default: 7, 15, 30, 60 → 0-7, 8-15, 16-30, 31-60, 61+");
        help.setStyle("-fx-text-fill: #666;");

        Button saveBtn = new Button("Save");
        saveBtn.setOnAction(e -> save());

        Button resetBtn = new Button("Reset to Defaults");
        resetBtn.setOnAction(e -> resetToDefaults());

        HBox actions = new HBox(10, saveBtn, resetBtn);
        statusLbl.setStyle("-fx-text-fill: #666;");

        VBox center = new VBox(12,
                new Label("These buckets are used in Overdue screen filter + exports."),
                form,
                help,
                actions,
                statusLbl
        );
        setCenter(center);

        load();
    }

    private void load() {
        try {
            b1Field.setText(settingsDao.get(OverduePolicyService.KEY_BUCKET1_MAX, "7"));
            b2Field.setText(settingsDao.get(OverduePolicyService.KEY_BUCKET2_MAX, "15"));
            b3Field.setText(settingsDao.get(OverduePolicyService.KEY_BUCKET3_MAX, "30"));
            b4Field.setText(settingsDao.get(OverduePolicyService.KEY_BUCKET4_MAX, "60"));
            statusLbl.setText("Loaded");
        } catch (SQLException e) {
            statusLbl.setText("Error: " + e.getMessage());
            new Alert(Alert.AlertType.ERROR, "Failed to load overdue settings\n\n" + e.getMessage()).showAndWait();
        }
    }

    private void save() {
        try {
            int b1 = parseDays(b1Field.getText());
            int b2 = parseDays(b2Field.getText());
            int b3 = parseDays(b3Field.getText());
            int b4 = parseDays(b4Field.getText());

            if (b2 < b1) throw new NumberFormatException("Bucket 2 max must be >= Bucket 1 max");
            if (b3 < b2) throw new NumberFormatException("Bucket 3 max must be >= Bucket 2 max");
            if (b4 < b3) throw new NumberFormatException("Bucket 4 max must be >= Bucket 3 max");

            settingsDao.set(OverduePolicyService.KEY_BUCKET1_MAX, Integer.toString(b1));
            settingsDao.set(OverduePolicyService.KEY_BUCKET2_MAX, Integer.toString(b2));
            settingsDao.set(OverduePolicyService.KEY_BUCKET3_MAX, Integer.toString(b3));
            settingsDao.set(OverduePolicyService.KEY_BUCKET4_MAX, Integer.toString(b4));

            statusLbl.setText("Saved ✅");
        } catch (NumberFormatException nfe) {
            new Alert(Alert.AlertType.WARNING, "Please enter valid days.\n\n" + nfe.getMessage()).showAndWait();
        } catch (SQLException e) {
            statusLbl.setText("Error: " + e.getMessage());
            new Alert(Alert.AlertType.ERROR, "Failed to save overdue settings\n\n" + e.getMessage()).showAndWait();
        }
    }

    private void resetToDefaults() {
        b1Field.setText("7");
        b2Field.setText("15");
        b3Field.setText("30");
        b4Field.setText("60");
        statusLbl.setText("Defaults loaded (click Save to apply)");
    }

    private int parseDays(String s) {
        int v = Integer.parseInt(s.trim());
        if (v < 0) throw new NumberFormatException("Days cannot be negative");
        if (v > 3650) throw new NumberFormatException("Days looks too large");
        return v;
    }
}

package com.gasstation.app;

import com.gasstation.app.db.Db;
import javafx.application.Application;
import javafx.stage.Stage;

public class App extends Application {

    @Override
    public void start(Stage stage) {
        stage.setTitle("Credit Accounting");

        AppNavigator nav = new AppNavigator(stage);
        nav.start();

        stage.show();
    }



    public static void main(String[] args) {
        Db.init();
        launch(args);
    }
    
    
}

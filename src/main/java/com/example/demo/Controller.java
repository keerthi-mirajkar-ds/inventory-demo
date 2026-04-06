package com.example.demo;

import org.springframework.web.bind.annotation.*;

@RestController
public class Controller {

    @GetMapping("/")
    public String root() {
        return "UP";
    }

    @GetMapping("/api/health")
    public String health() {
        return "UP";
    }

    @GetMapping("/api/inventory")
    public String inventory() {
        return "Inventory service running";
    }
}

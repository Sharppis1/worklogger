package api

import (
	"embed"
	"io/fs"
	"net/http"
)

//go:embed web/*
var dashboardFiles embed.FS

func dashboardHandler() http.Handler {
	root, err := fs.Sub(dashboardFiles, "web")
	if err != nil {
		panic(err)
	}
	return http.FileServer(http.FS(root))
}

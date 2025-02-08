/*
Copyright © 2021 NAME HERE <EMAIL ADDRESS>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

	http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package cmd

import (
	_ "embed"
	"fmt"
	"github.com/spf13/cobra"
	"gitlab.com/go-htmx/go-htmx/pkg/htmx"
	"net/http"
)

//go:embed stylesheet.css
var stylesheet string

//go:embed template.html
var template string

// BOILERPLATE code
// This way of making a handler allows to use templates, and provide other parameters, e.g. database connection parameters.
func makehandler(page func() htmx.RequestProcessor) func(w http.ResponseWriter, r *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		fmt.Println("Incoming HTTP request", r.Method, r.URL.String())
		ctx := htmx.NewContext(r)
		ctx.HxTarget = "#main" // Which part of the template is replaced by HTMX, by default
		if ctx.IsHtmxRequest {
			ctx.RequestHandler(w, page())
		} else {
			htmlstr := fmt.Sprintf(template, stylesheet,
				`<script src="https://unpkg.com/htmx.org@2.0.1" integrity="sha384-QWGpdj554B4ETpJJC9z+ZHJcA/i59TyjxEPXiiUgN2WmTyV5OEZWCD6gQhgkdpB/" crossorigin="anonymous"></script>`,
				ctx.RequestHandlerForTemplate(page()))
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_, err := w.Write([]byte(htmlstr))
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				fmt.Println("Incoming HTTP request completed with error")
				return
			}
		}
	}
}

// webserverCmd represents the webserver command
var webserverCmd = &cobra.Command{
	Use:   "webserver",
	Short: "Enables the BoxWallet web server",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		//component := headerTemplate("John")
		//http.Handle("/", templ.Handler(component))
		//
		//fmt.Println("Listening on :7070")
		//http.ListenAndServe(":7070", nil)
		//component.Render(context.Background(), os.Stdout)

		//r := mux.NewRouter()
		//r.HandleFunc("/dash/", makehandler(WebDash))
		//
		//fmt.Println("Starting server at port 7070")
		//fmt.Println("Try http://127.0.0.1:7070/dash")
		//if err := http.ListenAndServe(":7070", r); err != nil {
		//	fmt.Println("Failed to start server:", err)
		//}
	},
}

func init() {
	rootCmd.AddCommand(webserverCmd)

	// Here you will define your flags and configuration settings.

	// Cobra supports Persistent Flags which will work for this command
	// and all subcommands, e.g.:
	// webserverCmd.PersistentFlags().String("foo", "", "A help for foo")

	// Cobra supports local flags which will only run when this command
	// is called directly, e.g.:
	// webserverCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}

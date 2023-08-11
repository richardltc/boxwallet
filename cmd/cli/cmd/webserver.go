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
	"context"
	"flag"
	conf "github.com/ardanlabs/conf/v3"
	"log"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/api"
	"time"

	"github.com/spf13/cobra"
)

// build is the git version of this program. It is set using build flags in the makefile..
var (
	build = "develop"
	Ctx   = context.TODO()

	laddr = flag.String("addr", "127.0.0.1:3000", "Local address for the HTTP API")
)

// webserverCmd represents the webserver command
var webserverCmd = &cobra.Command{
	Use:   "webserver",
	Short: "Enables the BoxWallet web server",
	Long:  ``,
	Run: func(cmd *cobra.Command, args []string) {
		// =========================================================================
		// Configuration

		cfg := struct {
			conf.Version
			Web struct {
				APIHost         string        `conf:"default:127.0.0.1:3000"`
				ShutdownTimeout time.Duration `conf:"default:20s"`
			}
		}{
			Version: conf.Version{
				Build: build,
				Desc:  "copyright information here",
			},
		}

		// =========================================================================
		// Start API Service

		log.Println("startup", "status", "initializing V1 API support")

		apiV1 := api.RESTApiV1{}
		apiV1.Init()
		log.Println("startup", "status", "api router started", "host", cfg.Web.APIHost)
		apiV1.Serve(*laddr)

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

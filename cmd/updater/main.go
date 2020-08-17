package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"runtime"

	gwc "github.com/richardltc/gwcommon"

	m "richardmace.co.uk/godivi/pkg/models"
)

func main() {
	sAppName, err := gwc.GetAppName(gwc.APPTCLI)
	if err != nil {
		log.Fatal("Unable to GetAppName " + err.Error())
	}

	sAppCLIName, err := gwc.GetAppCLIName(gwc.APPTCLI)
	if err != nil {
		log.Fatal("Unable to GetAppCLIName " + err.Error())
	}

	sAppCLIFilename, err := gwc.GetAppFileName(gwc.APPTCLI) //GetAppCLIFileName()
	if err != nil {
		log.Fatal("Unable to GetAppFileName " + err.Error())
	}
	sAppInstallerFn, err := gwc.GetAppFileName(gwc.APPTInstaller)
	if err != nil {
		log.Fatal("Unable to GetAppInstallerFileName " + err.Error())
	}
	sAppUpdaterName, err := gwc.GetAppFileName(gwc.APPTUpdater)
	if err != nil {
		log.Fatal("Unable to GetAppFileName " + err.Error())
	}

	fmt.Println(sAppUpdaterName + " v" + gwc.CAppVersion + " Started...")
	// Check to make sure we're installed
	if !gwc.IsGoWalletInstalled(gwc.APPTCLI) {
		log.Fatal(sAppName + ` doesn't appear to be installed yet. Please run "` + sAppCLIFilename + ` install" first`)
	}

	// Check to make sure that the app (GoDivi) is not currently running
	gdr, _, err := gwc.IsAppCLIRunning()
	if err != nil {
		log.Fatal("Unable to determine if " + sAppCLIFilename + " is running - " + err.Error())
	}
	if gdr {
		log.Fatal(sAppCLIFilename + " is currently running.  Please close " + sAppCLIFilename + " and then run " + sAppUpdaterName + " again.")
	}

	dbf, _ := gwc.GetAppsBinFolder(gwc.APPTCLI)
	dir, err := gwc.GetRunningDir()
	if err != nil {
		log.Fatal("Unable to GetRunningDir " + err.Error())
	}

	var url, file string
	// Get download file link
	switch runtime.GOARCH {
	case "arm":
		url, file, err = gwc.GetGoWalletDownloadLink(gwc.OSTArm)
		if err != nil {
			log.Fatal("Unable to GetGoWalletDownloadLink " + err.Error())
		}
	case "amd64":
		url, file, err = gwc.GetGoWalletDownloadLink(gwc.OSTLinux)
		if err != nil {
			log.Fatal("Unable to GetGoWalletDownloadLink " + err.Error())
		}
	case "windows":
		url, file, err = gwc.GetGoWalletDownloadLink(gwc.OSTWindows)
		if err != nil {
			log.Fatal("Unable to GetGoWalletDownloadLink " + err.Error())
		}
	}

	// Download the file
	err = gwc.DownloadFile(dir, url+file)
	if err != nil {
		log.Fatal("Unable to download file: " + url + file + " - " + err.Error())
	}
	defer gwc.FileDelete(dir)

	// Unzip the file
	_, err = gwc.UnZip(dir+file, "./tmp")
	if err != nil {
		log.Fatal("Unable to unzip file: ", file, err)
	}
	defer gwc.FileDelete("./tmp")

	// Copy README.md
	err = gwc.FileCopy("./tmp/README.md", dbf+"README.md", false)
	if err != nil {
		log.Fatal("Unable to copy file: ", err)
	}

	// Copy CLI App
	err = gwc.FileCopy("./tmp/"+sAppInstallerFn, dbf+sAppCLIFilename, false)
	if err != nil {
		log.Fatal("Unable to copy file: ", err)
	}
	err = os.Chmod(dbf+sAppCLIFilename, 0777)
	if err != nil {
		log.Fatal("Unable to chmod file: ", err)
	}

	fmt.Println(sAppCLIName + " has been successfully updated to the latest version")
}

// func createEndpoint(args *args, path string) string {
// 	uri := "//" + *args.ipAddress + ":" + strconv.Itoa(*args.portNumber)
// 	myURL, err := url.Parse(uri)
// 	if err != nil {
// 		log.Fatal(err)
// 	}

// 	return "http://" + myURL.Host + path
// }

func tellGDServerToShutdown() gwc.ServerResponse {
	ss := m.ServerRequestStruct{}
	ss.ServerRequest = gwc.CServRequestShutdownServer
	requestBody, err := json.Marshal(ss)
	if err != nil {
		log.Fatal(err)
	}

	// We're just going to fire the request off, and then check for whether it's shutdown or not.
	_, _ = http.Post("http://127.0.0.1:4000/server/", "application/json", bytes.NewBuffer(requestBody))
	//resp, err := http.Post("http://127.0.0.1:4000/server/", "application/json", bytes.NewBuffer(requestBody))
	// if err != nil {
	// 	log.Fatal(err)
	// }
	// defer resp.Body.Close()

	// body, err := ioutil.ReadAll(resp.Body)
	// if err != nil {
	// 	log.Fatal(err)
	// }

	// if string(body) == "Server shutdown request detected, so shutting down" {
	// 	return gdc.NoServerError
	// }

	return gwc.NoServerError
}

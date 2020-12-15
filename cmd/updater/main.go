package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
	"runtime"

	"github.com/mitchellh/go-ps"
	gwc "github.com/richardltc/gwcommon"
	m "richardmace.co.uk/godivi/pkg/models"
)

const (
	cAppName              = "bwupdater"
	cAppCLIFileWinBoxDivi = "boxwallet.exe"
	cAppCLIFileBoxDivi    = "boxwallet"
	cAppVersion           = "0.35.1"
)

func main() {
	//sAppName, err := gwc.GetAppName(gwc.APPTCLI)
	//if err != nil {
	//	log.Fatal("Unable to GetAppName " + err.Error())
	//}

	//sAppCLIName, err := gwc.GetAppCLIName(gwc.APPTCLI)
	//if err != nil {
	//	log.Fatal("Unable to GetAppCLIName " + err.Error())
	//}
	//
	//sAppCLIFilename, err := gwc.GetAppFileName(gwc.APPTCLI) //GetAppCLIFileName()
	//if err != nil {
	//	log.Fatal("Unable to GetAppFileName " + err.Error())
	//}
	//sAppInstallerFn, err := gwc.GetAppFileName(gwc.APPTInstaller)
	//if err != nil {
	//	log.Fatal("Unable to GetAppInstallerFileName " + err.Error())
	//}
	//sAppUpdaterName, err := gwc.GetAppFileName(gwc.APPTUpdater)
	//if err != nil {
	//	log.Fatal("Unable to GetAppFileName " + err.Error())
	//}

	fmt.Println(cAppName + " v" + cAppVersion + " Started...")

	// Check to make sure that the app (BoxWallet) is not currently running
	gdr, _, err := isBoxWalletRunning()
	if err != nil {
		log.Fatal("Unable to determine if " + cAppCLIFileBoxDivi + " is running - " + err.Error())
	}
	if gdr {
		log.Fatal(cAppCLIFileBoxDivi + " is currently running.  Please close " + cAppCLIFileBoxDivi + " and then run " + cAppName + " again.")
	}

	//dbf, _ := gwc.GetAppsBinFolder(gwc.APPTCLI)
	//dir, err := gwc.GetRunningDir()
	//if err != nil {
	//	log.Fatal("Unable to GetRunningDir " + err.Error())
	//}
	ex, err := os.Executable()
	if err != nil {
		log.Fatal("unable to retrieve running binary: %v ", err)
	}
	dir := be.AddTrailingSlash(filepath.Dir(ex))

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

func isBoxWalletRunning() (bool, int, error) {
	var pid int
	var err error
	if runtime.GOOS == "windows" {
		pid, _, err = findProcess(cAppCLIFileWinBoxDivi)
	} else {
		pid, _, err = findProcess(cAppCLIFileBoxDivi)
	}

	if err == nil {
		return true, pid, nil
	} else if err.Error() == "not found" {
		return false, 0, nil
	} else {
		return false, 0, err
	}
}

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

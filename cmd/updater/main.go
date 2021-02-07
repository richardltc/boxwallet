package main

import (
	"encoding/json"
	"fmt"
	"github.com/mholt/archiver/v3"

	//gwc "github.com/richardltc/gwcommon"
	"io/ioutil"
	"log"
	"net/http"
	"os"
	"path/filepath"
	be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
	"runtime"
	"time"
)

const (
//cAppName = "bwupdater"
//cAppCLIFileWinBoxDivi = "boxwallet.exe"
//cAppCLIFileBoxDivi    = "boxwallet"
//cAppVersion = be.CBWAppVersion
)

type githubInfo struct {
	URL       string `json:"url"`
	AssetsURL string `json:"assets_url"`
	UploadURL string `json:"upload_url"`
	HTMLURL   string `json:"html_url"`
	ID        int    `json:"id"`
	Author    struct {
		Login             string `json:"login"`
		ID                int    `json:"id"`
		NodeID            string `json:"node_id"`
		AvatarURL         string `json:"avatar_url"`
		GravatarID        string `json:"gravatar_id"`
		URL               string `json:"url"`
		HTMLURL           string `json:"html_url"`
		FollowersURL      string `json:"followers_url"`
		FollowingURL      string `json:"following_url"`
		GistsURL          string `json:"gists_url"`
		StarredURL        string `json:"starred_url"`
		SubscriptionsURL  string `json:"subscriptions_url"`
		OrganizationsURL  string `json:"organizations_url"`
		ReposURL          string `json:"repos_url"`
		EventsURL         string `json:"events_url"`
		ReceivedEventsURL string `json:"received_events_url"`
		Type              string `json:"type"`
		SiteAdmin         bool   `json:"site_admin"`
	} `json:"author"`
	NodeID          string    `json:"node_id"`
	TagName         string    `json:"tag_name"`
	TargetCommitish string    `json:"target_commitish"`
	Name            string    `json:"name"`
	Draft           bool      `json:"draft"`
	Prerelease      bool      `json:"prerelease"`
	CreatedAt       time.Time `json:"created_at"`
	PublishedAt     time.Time `json:"published_at"`
	Assets          []struct {
		URL      string `json:"url"`
		ID       int    `json:"id"`
		NodeID   string `json:"node_id"`
		Name     string `json:"name"`
		Label    string `json:"label"`
		Uploader struct {
			Login             string `json:"login"`
			ID                int    `json:"id"`
			NodeID            string `json:"node_id"`
			AvatarURL         string `json:"avatar_url"`
			GravatarID        string `json:"gravatar_id"`
			URL               string `json:"url"`
			HTMLURL           string `json:"html_url"`
			FollowersURL      string `json:"followers_url"`
			FollowingURL      string `json:"following_url"`
			GistsURL          string `json:"gists_url"`
			StarredURL        string `json:"starred_url"`
			SubscriptionsURL  string `json:"subscriptions_url"`
			OrganizationsURL  string `json:"organizations_url"`
			ReposURL          string `json:"repos_url"`
			EventsURL         string `json:"events_url"`
			ReceivedEventsURL string `json:"received_events_url"`
			Type              string `json:"type"`
			SiteAdmin         bool   `json:"site_admin"`
		} `json:"uploader"`
		ContentType        string    `json:"content_type"`
		State              string    `json:"state"`
		Size               int       `json:"size"`
		DownloadCount      int       `json:"download_count"`
		CreatedAt          time.Time `json:"created_at"`
		UpdatedAt          time.Time `json:"updated_at"`
		BrowserDownloadURL string    `json:"browser_download_url"`
	} `json:"assets"`
	TarballURL string `json:"tarball_url"`
	ZipballURL string `json:"zipball_url"`
	Body       string `json:"body"`
}

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

	fmt.Println(be.CUpdaterAppName + " v" + be.CBWAppVersion + " Started...")

	// Check to make sure that the app (BoxWallet) is not currently running
	bbwRunning, _, err := isBoxWalletRunning()
	if err != nil {
		log.Fatal("Unable to determine if " + be.CAppName + " is running - " + err.Error())
	}
	if bbwRunning {
		log.Fatal(be.CAppName + " is currently running.  Please close " + be.CAppName + " and then run " + be.CUpdaterAppName + " again.")
	}
	fmt.Println(be.CAppName + " is not running, so checking online for latest version...")

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
	tmpDir := dir + be.AddTrailingSlash("tmp")

	var url, compressedFN, bwFile string

	// Get download compressedFN link
	sTag, err := getLatestVersionTag()
	if err != nil {
		log.Fatal("Unable to getLatestVersionTag " + err.Error())
	}

	fmt.Println("Latest release detected is: " + sTag)

	// example link https://github.com/richardltc/boxwallet/releases/download/0.36.10/boxwallet_0.36.10_Linux_64bit.tar.gz
	url = "https://github.com/richardltc/boxwallet/releases/download/" + sTag + "/"
	//compressedFN = "boxwallet_" + sTag + "_Linux_64bit.tar.gz"

	switch runtime.GOOS {
	case "darwin":
		compressedFN = "boxwallet_" + sTag + "_macOS_64bit.tar.gz"
		bwFile = be.CAppFilename
	case "windows":
		compressedFN = "boxwallet_" + sTag + "_Windows_64bit.zip"
		bwFile = be.CAppFilenameWin
	case "linux":
		bwFile = be.CAppFilename
		switch runtime.GOARCH {
		case "386":
			compressedFN = "boxwallet_" + sTag + "_Linux_32bit.tar.gz"
		case "arm":
			compressedFN = "boxwallet_" + sTag + "_Linux_arm32bit.tar.gz"
		case "arm64":
			compressedFN = "boxwallet_" + sTag + "_Linux_arm64.tar.gz"
		case "amd64":
			compressedFN = "boxwallet_" + sTag + "_Linux_64bit.tar.gz"
		default:
			log.Fatal("Unable to determine GOARCH type")
		}
	default:
		log.Fatal("Unable to determine OS type")
	}

	// Download the compressedFN
	if err := be.DownloadFile(dir, url+compressedFN); err != nil {
		log.Fatal("unable to download compressedFN: ", url+compressedFN, err)
	}
	defer os.Remove(dir + compressedFN)

	if err := archiver.Unarchive(dir+compressedFN, tmpDir); err != nil {
		log.Fatal("unable to un-archive compressedFN: ", err)
	}
	defer os.RemoveAll(tmpDir)

	//// Remove the existing README.md file
	//fmt.Println("Attempting to delete old README.md file...")
	//_ = os.Remove(dir + "README.md")

	// Copy README.md
	if err := be.FileCopy(tmpDir+"README.md", dir+"README.md", false); err != nil {
		log.Fatal("Unable to copy "+tmpDir+"README.md"+" to "+dir+"README.md"+": ", err)
	}

	// Backup existing boxwallet file
	fmt.Println("Attempting backup of existing " + be.CAppName + " file...")
	if err := be.BackupFile(dir, bwFile, dir, "", false); err != nil {
		log.Fatal("Unable to copy to backup : ", err)
	}

	//// Remove the old boxwallet binary file
	//fmt.Println("Attempting to delete old "  + be.CAppName + " file...")
	//if err := os.Remove(dir + bwFile); err != nil {
	//	log.Fatal("Unable to delete old "+ be.CAppName + " file...", err)
	//}

	// Copy boxwallet
	if err := be.FileCopy(tmpDir+bwFile, dir+bwFile, false); err != nil {
		log.Fatal("Unable to copy "+tmpDir+bwFile+" to "+dir+bwFile+": ", err)
	}

	fmt.Println("Updating permissions on new " + be.CAppName + " file...")
	err = os.Chmod(dir+bwFile, 0777)
	if err != nil {
		log.Fatal("Unable to chmod new boxwallet file: ", err)
	}

	fmt.Println(be.CAppName + " has been successfully updated to the latest version: " + sTag)
}

// func createEndpoint(args *args, path string) string {
// 	uri := "//" + *args.ipAddress + ":" + strconv.Itoa(*args.portNumber)
// 	myURL, err := url.Parse(uri)
// 	if err != nil {
// 		log.Fatal(err)
// 	}

// 	return "http://" + myURL.Host + path
// }

func getLatestVersionTag() (string, error) {
	var ghInfo githubInfo

	resp, err := http.Get("https://api.github.com/repos/richardltc/boxwallet/releases/latest")
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	err = json.Unmarshal(body, &ghInfo)
	if err != nil {
		return "", err
	}
	return ghInfo.TagName, nil
}

func isBoxWalletRunning() (bool, int, error) {
	var pid int
	var err error
	if runtime.GOOS == "windows" {
		pid, _, err = be.FindProcess(be.CAppFilenameWin)
	} else {
		pid, _, err = be.FindProcess(be.CAppFilename)
	}

	if err == nil {
		return true, pid, nil
	} else if err.Error() == "not found" {
		return false, 0, nil
	} else {
		return false, 0, err
	}
}

//func tellGDServerToShutdown() gwc.ServerResponse {
//	ss := m.ServerRequestStruct{}
//	ss.ServerRequest = gwc.CServRequestShutdownServer
//	requestBody, err := json.Marshal(ss)
//	if err != nil {
//		log.Fatal(err)
//	}
//
//	// We're just going to fire the request off, and then check for whether it's shutdown or not.
//	_, _ = http.Post("http://127.0.0.1:4000/server/", "application/json", bytes.NewBuffer(requestBody))
//	//resp, err := http.Post("http://127.0.0.1:4000/server/", "application/json", bytes.NewBuffer(requestBody))
//	// if err != nil {
//	// 	log.Fatal(err)
//	// }
//	// defer resp.Body.Close()
//
//	// body, err := ioutil.ReadAll(resp.Body)
//	// if err != nil {
//	// 	log.Fatal(err)
//	// }
//
//	// if string(body) == "Server shutdown request detected, so shutting down" {
//	// 	return gdc.NoServerError
//	// }
//
//	return gwc.NoServerError
//}

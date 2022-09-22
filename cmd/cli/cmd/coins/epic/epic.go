package epic

import (
	"encoding/json"
	"errors"
	"fmt"
	"github.com/mholt/archiver"
	"io/ioutil"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/fileutils"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/rjminternet"
	"runtime"
	"strings"
)

const (
	cCoinName       string = "EPIC Cash"
	cCoinNameAbbrev string = "EPIC"

	cCoreVersion     string = "3.0.0"
	cDownloadFileLin string = "epiccash_E3_node-server_ubuntu.zip" //+ cCoreVersion + "-linux64.tar.gz"
	cDownloadFileWin string = "epiccash_E3_node-server_win.zip"    //+ cCoreVersion + "-win64-setup.exe"

	cExtractedDirLin = "epiccash_E3_node-server_ubuntu/"
	cExtractedDirWin = "epiccash_E3_node-server\\"

	cDownloadURL string = "https://dl.epic.tech/" //+ cCoreVersion + "/"
	//cDownloadURLBS string = "https://51pool.online/downloads/"
	cDownloadURLBS string = "https://epiccash.s3.sa-east-1.amazonaws.com/"

	//cDownloadFileBS string = "epic_chain_data.tar.gz"
	cDownloadFileBS string = "mainnet.zip"

	cHomeDirLin string = ".epic/main"
	cHomeDirWin string = ".epic\\main"

	cConfFile      string = "epic-server.toml"
	cDaemonFileLin string = "epic"
	cDaemonFileWin string = "epic.exe"

	cTipAddress string = "vite_cce4bfb523231fa3986d360416aa985500e25aba0ae5cfd0a8"

	// epiccash file constants
	cRPCUser string = "epic"
	cRPCPort string = "18332"
)

type EPIC struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

func (e EPIC) Bootstrap(rpcUser, rpcPassword, ip, port string) {
	e.RPCUser = rpcUser
	e.RPCPassword = rpcPassword
	e.IPAddress = ip
	e.Port = port
}

func (e EPIC) AbbreviatedCoinName() string {
	return cCoinNameAbbrev
}

func (e EPIC) AllBinaryFilesExist(dir string) (bool, error) {
	if runtime.GOOS == "windows" {
		if !fileutils.FileExists(dir + cDaemonFileWin) {
			return false, nil
		}
	} else {
		if !fileutils.FileExists(dir + cDaemonFileLin) {
			return false, nil
		}
	}

	return true, nil
}

// BlockchainDataExists - Returns true if the Blockchain data exists for the specified coin
func (e EPIC) BlockchainDataExists() (bool, error) {
	coinDir, err := e.HomeDirFullPath()
	if err != nil {
		return false, errors.New("unable to HomeDirFullPath - BlockchainDataExists")
	}

	// If the "chain_data" directory already exists, return
	if _, err := os.Stat(coinDir + "chains_data"); !os.IsNotExist(err) {
		err := errors.New("The directory: " + coinDir + "chain_data already exists")
		return true, err
	}

	return false, nil
}

func (e EPIC) ConfFile() string {
	return cConfFile
}

func (e EPIC) CoinName() string {
	return cCoinName
}

func (e EPIC) CoinNameAbbrev() string {
	return cCoinNameAbbrev
}

func (e EPIC) DaemonRunning() (bool, error) {
	var err error

	if runtime.GOOS == "windows" {
		_, _, err = coins.FindProcess(cDaemonFileWin)
	} else {
		_, _, err = coins.FindProcess(cDaemonFileLin)
	}

	if err == nil {
		return true, nil
	}
	if err.Error() == "not found" {
		return false, nil
	} else {
		return false, err
	}
}

func (e EPIC) DownloadBlockchain() error {
	coinDir, err := e.HomeDirFullPath()
	if err != nil {
		return errors.New("unable to get HomeDirFullPath: " + err.Error())
	}
	bcsFileExists := fileutils.FileExists(coinDir + cDownloadFileBS)
	if !bcsFileExists {
		// Then download the file.
		if err := rjminternet.DownloadFile(coinDir+cDownloadFileBS, cDownloadURLBS+cDownloadFileBS); err != nil {
			return fmt.Errorf("unable to download file: %v - %v", cDownloadURLBS+cDownloadFileBS, err)
		}
	}

	return nil
}

// DownloadCoin - Downloads the Syscoin files into the spcified location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (e EPIC) DownloadCoin(location string) error {
	var fullFilePath, fullFileDLURL string

	switch runtime.GOOS {
	case "windows":
		fullFilePath = location + cDownloadFileWin
		fullFileDLURL = cDownloadURL + cDownloadFileWin
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			return errors.New("arm32 is not currently supported for :" + cCoinName)
		case "arm64":
			return errors.New("arm64 is not currently supported for :" + cCoinName)
		case "386":
			return errors.New("linux 386 is not currently supported for :" + cCoinName)
		case "amd64":
			fullFilePath = location + cDownloadFileLin
			fullFileDLURL = cDownloadURL + cDownloadFileLin
		}
	}

	if err := rjminternet.DownloadFile(fullFilePath, fullFileDLURL); err != nil {
		return fmt.Errorf("unable to download file: %v - %v", fullFilePath+fullFileDLURL, err)
	}

	// Unarchive the files
	if err := e.unarchiveFile(fullFilePath, location); err != nil {
		return err
	}
	return nil
}

func (e EPIC) DaemonFilename() string {
	if runtime.GOOS == "windows" {
		return cDaemonFileWin
	} else {
		return cDaemonFileLin
	}
}

func (e EPIC) HomeDir() string {
	if runtime.GOOS == "windows" {
		return cHomeDirWin
	} else {
		return cHomeDirLin
	}
}

func (e EPIC) HomeDirFullPath() (string, error) {
	u, err := user.Current()
	if err != nil {
		return "", err
	}
	hd := u.HomeDir

	if runtime.GOOS == "windows" {
		return fileutils.AddTrailingSlash(hd) + fileutils.AddTrailingSlash(cHomeDirWin), nil
	} else {
		return fileutils.AddTrailingSlash(hd) + fileutils.AddTrailingSlash(cHomeDirLin), nil
	}
}

// Install - Puts the freshly downloaded files into their correct location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (e EPIC) Install(location string) error {

	// Copy files to correct location
	var srcPath, sfD string

	switch runtime.GOOS {
	case "windows":
		srcPath = location + cExtractedDirWin
		sfD = cDaemonFileWin
	case "linux":
		switch runtime.GOARCH {
		case "arm", "arm64":
			srcPath = location + cExtractedDirLin
			sfD = cDaemonFileLin
		case "amd64":
			srcPath = location + cExtractedDirLin
			sfD = cDaemonFileLin
		default:
			return errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
		}
	default:
		return errors.New("unable to determine runtime.GOOS")
	}

	// If the coind file doesn't already exists the copy it.
	if _, err := os.Stat(location + sfD); os.IsNotExist(err) {
		if err := fileutils.FileCopy(srcPath+sfD, location+sfD, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+sfD, location+sfD, err)
		}
	}
	if err := os.Chmod(location+sfD, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+sfD, err)
	}

	return nil
}

func (e EPIC) RPCDefaultUsername() string {
	return cRPCUser
}

func (e EPIC) RPCDefaultPort() string {
	return cRPCPort
}

func (e EPIC) StartDaemon(displayOutput bool, appFolder string) error {
	b, _ := e.DaemonRunning()
	if b {
		return nil
	}

	if runtime.GOOS == "windows" {
		fp := appFolder + cDaemonFileWin
		cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
		if err := cmd.Run(); err != nil {
			return err
		}
	} else {
		if displayOutput {
			fmt.Println("Attempting to run the " + cCoinName + " daemon...")
		}

		cmdRun := exec.Command(appFolder + cDaemonFileLin)
		//stdout, err := cmdRun.StdoutPipe()
		//if err != nil {
		//	return err
		//}
		if err := cmdRun.Start(); err != nil {
			return err
		}
		if displayOutput {
			fmt.Println(cCoinName + " server starting")
		}

	}

	return nil
}

func (e EPIC) StopDaemon(auth *models.CoinAuth) error {
	//var respStruct models.GenericResponse

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"stop\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+auth.IPAddress+":"+auth.Port, body)
	if err != nil {
		return err
	}
	req.SetBasicAuth(auth.RPCUser, auth.RPCPassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	return nil
}

func (e EPIC) TipAddress() string {
	return cTipAddress
}

func (e EPIC) Status(auth *models.CoinAuth) (models.FTCWalletInfo, error) {
	var respStruct models.FTCWalletInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getwalletinfo\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+auth.IPAddress+":"+auth.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(auth.RPCUser, auth.RPCPassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return respStruct, err
	}
	defer resp.Body.Close()
	bodyResp, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return respStruct, err
	}

	err = json.Unmarshal(bodyResp, &respStruct)
	if err != nil {
		return respStruct, err
	}

	// Check to see if the json response contains "unlocked_until"
	s := string([]byte(bodyResp))
	if !strings.Contains(s, "unlocked_until") {
		respStruct.Result.UnlockedUntil = -1
	}

	return respStruct, nil
}

func (e EPIC) UnarchiveBlockchainSnapshot() error {
	coinDir, err := e.HomeDirFullPath()
	if err != nil {
		return errors.New("unable to get HomeDirFul - " + err.Error())
	}

	// First, check to make sure that both the blockchain folders don't already exist. (blocks, chainstate)
	bcsFileExists := fileutils.FileExists(coinDir + cDownloadFileBS)
	if !bcsFileExists {
		return errors.New("unable to find the snapshot file: " + coinDir + cDownloadFileBS)
	}

	// Now extract it straight into the ~/.epic/main folder
	if err := archiver.Unarchive(coinDir+cDownloadFileBS, coinDir); err != nil {
		return errors.New("unable to unarchive file: " + coinDir + cDownloadFileBS + " " + err.Error())
	}

	return nil
}

func (e EPIC) unarchiveFile(fullFilePath, location string) error {
	if err := archiver.Unarchive(fullFilePath, location); err != nil {
		return fmt.Errorf("unable to unarchive file: %v - %v", fullFilePath, err)
	}
	switch runtime.GOOS {
	case "windows":
		defer os.RemoveAll(location + cDownloadFileWin)
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			return errors.New("arm32 is not currently supported for :" + cCoinName)
		case "arm64":
			return errors.New("arm64 is not currently supported for :" + cCoinName)
		case "386":
			return errors.New("linux 386 is not currently supported for :" + cCoinName)
		case "amd64":
			defer os.RemoveAll(location + cDownloadFileLin)
		}
	}

	defer os.Remove(fullFilePath)

	return nil
}

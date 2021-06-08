package bend

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/ioutil"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/fileutils"
	"runtime"
	"strings"
	"time"

	"github.com/mholt/archiver"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/rjminternet"
)

const (
	cCoinName       string = "DeVault"
	cCoinNameAbbrev string = "DVT"

	cCoreVersion string = "1.2.1"

	cDownloadFileArm64 string = "devault-" + cCoreVersion + "-arm64-linuxgnuaarch.tar.gz"
	cDownloadFileLinux string = "devault-" + cCoreVersion + "-x86_64-linux-gnu.tar.gz"
	cDownloadFileWin   string = "devault-" + cCoreVersion + "-win64.zip"

	cExtractedDirLin = "devault-" + cCoreVersion + "-x86_64-linux-gnu/"
	cExtractedDirWin = "devault-" + cCoreVersion + "-x86_64-w64-mingw32\\"

	cDownloadURL string = "https://github.com/devaultcrypto/devault/releases/download/v" + cCoreVersion + "/"

	cHomeDirLin string = ".devault"
	cHomeDirWin string = "DEVAULT"

	cTipAddress string = "devault:qp7w4pnm774c0uwch8ty6tj7sw86hze9ps4sqrwcue"

	cConfFile      string = "devault.conf"
	cCliFile       string = "devault-cli"
	cCliFileWin    string = "devault-cli.exe"
	cDaemonFile    string = "devaultd"
	cDaemonFileWin string = "devaultd.exe"
	cTxFile        string = "devault-tx"
	cTxFileWin     string = "devault-tx.exe"

	cRPCUser string = "devaultrpc"
	cRPCPort string = "3339"
)

type DeVault struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

func (d DeVault) Bootstrap(rpcUser, rpcPassword, ip, port string) {
	d.RPCUser = rpcUser
	d.RPCPassword = rpcPassword
	d.IPAddress = ip
	d.Port = port
}

func (d DeVault) AbbreviatedCoinName() string {
	return cCoinNameAbbrev
}

func (d DeVault) AllBinaryFilesExist(dir string) (bool, error) {
	if runtime.GOOS == "windows" {
		if !fileutils.FileExists(dir + cCliFileWin) {
			return false, nil
		}
		if !fileutils.FileExists(dir + cDaemonFileWin) {
			return false, nil
		}
		if !fileutils.FileExists(dir + cTxFileWin) {
			return false, nil
		}
	} else {
		if !fileutils.FileExists(dir + cCliFile) {
			return false, nil
		}
		if !fileutils.FileExists(dir + cDaemonFile) {
			return false, nil
		}
		if !fileutils.FileExists(dir + cTxFile) {
			return false, nil
		}
	}
	return true, nil
}

func (d DeVault) ConfFile() string {
	return cConfFile
}

func (d DeVault) CoinName() string {
	return cCoinName
}

func (s DeVault) CoinNameAbbrev() string {
	return cCoinNameAbbrev
}

// DownloadCoin - Downloads the Syscoin files into the spcified location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (d DeVault) DownloadCoin(location string) error {
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
			fullFilePath = location + cDownloadFileArm64
			fullFileDLURL = cDownloadURL + cDownloadFileArm64
		case "386":
			fullFilePath = location + cDownloadFileLinux
			fullFileDLURL = cDownloadURL + cDownloadFileLinux
		case "amd64":
			fullFilePath = location + cDownloadFileLinux
			fullFileDLURL = cDownloadURL + cDownloadFileLinux
		}
	}

	if err := rjminternet.DownloadFile(fullFilePath, fullFileDLURL); err != nil {
		return fmt.Errorf("unable to download file: %v - %v", fullFilePath+fullFileDLURL, err)
	}

	// Unarchive the files
	if err := d.unarchiveFile(fullFilePath, location); err != nil {
		return err
	}
	return nil
}

func (d DeVault) DaemonFilename() string {
	if runtime.GOOS == "windows" {
		return cDaemonFileWin
	} else {
		return cDaemonFile
	}
}

func (d *DeVault) GetBlockchainInfo() (models.DVTBlockchainInfo, error) {
	var respStruct models.DVTBlockchainInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getblockchaininfo\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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
	return respStruct, nil
}

func (d *DeVault) GetInfo() (models.DeVaultGetInfo, error) {

	var respStruct models.DeVaultGetInfo

	for i := 1; i < 50; i++ {
		//fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getinfo\",\"params\":[]}")
		req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
		if err != nil {
			return respStruct, err
		}
		req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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

		// Check to make sure we are not loading the wallet
		if bytes.Contains(bodyResp, []byte("Loading")) ||
			bytes.Contains(bodyResp, []byte("Rewinding")) ||
			bytes.Contains(bodyResp, []byte("Verifying")) {
			// The wallet is still loading, so print message, and sleep for 3 seconds and try again..
			var errStruct models.GenericResponse
			err = json.Unmarshal(bodyResp, &errStruct)
			if err != nil {
				return respStruct, err
			}
			//fmt.Println("Waiting for wallet to load...")
			time.Sleep(5 * time.Second)
		} else {

			_ = json.Unmarshal(bodyResp, &respStruct)
			return respStruct, err
		}
	}
	return respStruct, nil
}

func (d *DeVault) GetNetworkInfo() (models.DVTNetworkInfo, error) {
	var respStruct models.DVTNetworkInfo

	for i := 1; i < 50; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getnetworkinfo\",\"params\":[]}")

		req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
		if err != nil {
			return respStruct, err
		}
		req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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

		// Check to make sure we are not loading the wallet
		if bytes.Contains(bodyResp, []byte("Loading")) {
			// The wallet is still loading, so print message, and sleep for 3 seconds and try again...
			time.Sleep(5 * time.Second)
		} else {
			_ = json.Unmarshal(bodyResp, &respStruct)
			return respStruct, err
		}
	}
	return respStruct, nil
}

func (d *DeVault) GetWalletInfo() (models.DVTWalletInfo, error) {
	var respStruct models.DVTWalletInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getwalletinfo\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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

func (d *DeVault) GetWalletSecurityState(wi *models.DVTWalletInfo) models.WEType {
	if wi.Result.UnlockedUntil == 0 {
		return models.WETLocked
	} else if wi.Result.UnlockedUntil == -1 {
		return models.WETUnencrypted
	} else if wi.Result.UnlockedUntil > 0 {
		return models.WETUnlockedForStaking
	} else {
		return models.WETUnknown
	}
}

func (d DeVault) HomeDir() string {
	if runtime.GOOS == "windows" {
		return cHomeDirWin
	} else {
		return cHomeDirLin
	}
}

func (d DeVault) HomeDirFullPath() (string, error) {
	u, err := user.Current()
	if err != nil {
		return "", err
	}
	hd := u.HomeDir

	if runtime.GOOS == "windows" {
		return fileutils.AddTrailingSlash(hd) + "appdata\\roaming\\" + fileutils.AddTrailingSlash(cHomeDirWin), nil
	} else {
		return fileutils.AddTrailingSlash(hd) + fileutils.AddTrailingSlash(cHomeDirLin), nil
	}
}

// Install - Puts the freshly downloaded files into their correct location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (d DeVault) Install(location string) error {

	// Copy files to correct location
	var srcPath, sfCLI, sfD, sfTX, dirToRemove string

	switch runtime.GOOS {
	case "windows":
		srcPath = location + cDownloadFileWin
		sfCLI = cCliFileWin
		sfD = cDaemonFileWin
		sfTX = cTxFileWin
	case "linux":
		switch runtime.GOARCH {
		case "arm", "arm64":
			srcPath = location + cExtractedDirLin + "bin/"
			sfCLI = cCliFile
			sfD = cDaemonFile
			sfTX = cTxFile
			dirToRemove = location + cExtractedDirLin
		case "amd64":
			srcPath = location + cExtractedDirLin + "bin/"
			sfCLI = cCliFile
			sfD = cDaemonFile
			sfTX = cTxFile
			dirToRemove = location + cExtractedDirLin
		default:
			return errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
		}
	default:
		return errors.New("unable to determine runtime.GOOS")
	}

	// If the coin-cli file doesn't already exists the copy it.
	if _, err := os.Stat(location + sfCLI); os.IsNotExist(err) {
		if err := fileutils.FileCopy(srcPath+sfCLI, location+sfCLI, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+sfCLI, location+sfCLI, err)
		}
	}
	if err := os.Chmod(location+sfCLI, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+sfCLI, err)
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

	// If the cointx file doesn't already exists the copy it.
	if _, err := os.Stat(location + sfTX); os.IsNotExist(err) {
		if err := fileutils.FileCopy(srcPath+sfTX, location+sfTX, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+sfTX, location+sfTX, err)
		}
	}
	if err := os.Chmod(location+sfTX, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+sfTX, err)
	}

	if err := os.RemoveAll(dirToRemove); err != nil {
		return err
	}

	return nil
}

func (d *DeVault) ListReceivedByAddress(includeZero bool) (models.DVTListReceivedByAddress, error) {
	var respStruct models.DVTListReceivedByAddress

	var s string
	if includeZero {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, true]}"
	} else {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, false]}"
	}
	body := strings.NewReader(s)
	req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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

	return respStruct, nil
}

func (d DeVault) RPCDefaultUsername() string {
	return cRPCUser
}

func (d DeVault) RPCDefaultPort() string {
	return cRPCPort
}

func (d DeVault) StartDaemon(displayOutput bool) error {
	if runtime.GOOS == "windows" {
		//_ = exec.Command(GetAppsBinFolder() + cDiviDFileWin)
		fp := cHomeDirWin + cDaemonFileWin
		cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
		if err := cmd.Run(); err != nil {
			return err
		}
	} else {
		if displayOutput {
			fmt.Println("Attempting to run the devault daemon...")
		}

		args := []string{"-bypasspassword"}
		cmdRun := exec.Command(cHomeDirLin+cDaemonFile, args...)
		err := cmdRun.Start()
		if err != nil {
			return err
		}
		fmt.Println("DeVault server starting")
	}
	return nil
}

func (d *DeVault) StopDaemon(displayOut bool) (models.GenericResponse, error) {
	var respStruct models.GenericResponse

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"stop\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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
	return respStruct, nil
}

func (d DeVault) TipAddress() string {
	return cTipAddress
}

func (d *DeVault) UnlockWallet(pw string) error {
	var respStruct models.GenericResponse

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",0]}")
	req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
	if err != nil {
		return err
	}
	req.SetBasicAuth(d.RPCUser, d.RPCPassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	bodyResp, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	err = json.Unmarshal(bodyResp, &respStruct)
	if err != nil {
		return err
	}
	return nil
}

func (d *DeVault) WalletSecurityState() (models.WEType, error) {
	wi, err := d.GetWalletInfo()
	if err != nil {
		return models.WETUnknown, errors.New("Unable to GetWalletSecurityState: " + err.Error())
	}

	if wi.Result.UnlockedUntil == 0 {
		return models.WETLocked, nil
	} else if wi.Result.UnlockedUntil == -1 {
		return models.WETUnencrypted, nil
	} else if wi.Result.UnlockedUntil > 0 {
		return models.WETUnlockedForStaking, nil
	} else {
		return models.WETUnknown, nil
	}
}

func (d *DeVault) unarchiveFile(fullFilePath, location string) error {
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
			defer os.RemoveAll(location + cDownloadFileArm64)
		case "386":
			defer os.RemoveAll(location + cDownloadFileLinux)
		case "amd64":
			defer os.RemoveAll(location + cDownloadFileLinux)
		}
	}

	defer os.Remove(fullFilePath)

	return nil
}

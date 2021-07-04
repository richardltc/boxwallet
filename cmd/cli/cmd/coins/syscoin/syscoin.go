package coins

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
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/fileutils"
	"runtime"
	"strconv"
	"strings"

	"github.com/mholt/archiver/v3"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/rjminternet"
)

const (
	cCoinName       string = "Syscoin"
	cCoinNameAbbrev string = "SYS"

	cCoreVersion       string = "4.2.2"
	cDownloadFileArm32        = "syscoin-" + cCoreVersion + "-arm-linux-gnueabihf.tar.gz"
	cDownloadFileArm64        = "syscoin-" + cCoreVersion + "-aarch64-linux-gnu.tar.gz"
	cDownloadFileLin          = "syscoin-" + cCoreVersion + "-x86_64-linux-gnu.tar.gz"
	cDownloadFilemacOS        = "syscoin-" + cCoreVersion + "-osx64.tar.gz"
	cDownloadFileWin          = "syscoin-" + cCoreVersion + "-win64.zip"

	// Directory const
	cExtractedDirArm string = "syscoin-" + cCoreVersion + "/"
	cExtractedDirLin string = "syscoin-" + cCoreVersion + "/"
	cExtractedDirWin string = "syscoin-" + cCoreVersion + "\\"

	cDownloadURL string = "https://github.com/syscoin/syscoin/releases/download/v" + cCoreVersion + "/"

	// Syscoin Wallet Constants
	cHomeDir    string = ".syscoin"
	cHomeDirWin string = "syscoin"

	// File constants
	cConfFile      string = "syscoin.conf"
	cCliFile       string = "syscoin-cli"
	cCliFileWin    string = "syscoin-cli.exe"
	cDaemonFileLin string = "syscoind"
	cDaemonFileWin string = "syscoind.exe"
	cTxFile        string = "syscoin-tx"
	cTxFileWin     string = "syscoin-tx.exe"

	cTipAddress string = "sys1qkj3tfnpndluj85k5vmfzccxfsl6nt4kn6slxey"

	cWalletName string = "mainwallet"

	cRPCUser string = "syscoinrpc"
	cRPCPort string = "8370"
)

type Syscoin struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

func (s Syscoin) Bootstrap(rpcUser, rpcPassword, ip, port string) {
	s.RPCUser = rpcUser
	s.RPCPassword = rpcPassword
	s.IPAddress = ip
	s.Port = port
}

func (s Syscoin) AbbreviatedCoinName() string {
	return cCoinNameAbbrev
}

func (s Syscoin) AllBinaryFilesExist(dir string) (bool, error) {
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
		if !fileutils.FileExists(dir + cDaemonFileLin) {
			return false, nil
		}
		if !fileutils.FileExists(dir + cTxFile) {
			return false, nil
		}
	}
	return true, nil
}

func (s Syscoin) BlockchainInfo(auth *models.CoinAuth) (models.SYSBlockchainInfo, error) {
	var respStruct models.SYSBlockchainInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getblockchaininfo\",\"params\":[]}")
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
	return respStruct, nil
}

func (s Syscoin) BlockchainIsSynced(coinAuth *models.CoinAuth) (bool, error) {
	bci, err := s.BlockchainInfo(coinAuth)
	if err != nil {
		return false, err
	}

	if bci.Result.Verificationprogress > 0.99999 {
		return true, nil
	}

	return false, nil
}

func (s Syscoin) ConfFile() string {
	return cConfFile
}

func (s Syscoin) CoinName() string {
	return cCoinName
}

func (s Syscoin) CoinNameAbbrev() string {
	return cCoinNameAbbrev
}

func (s Syscoin) DaemonFilename() string {
	if runtime.GOOS == "windows" {
		return cDaemonFileWin
	}

	return cDaemonFileLin
}

func (s Syscoin) DaemonRunning() (bool, error) {
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

// DownloadCoin - Downloads the Syscoin files into the spcified location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (s Syscoin) DownloadCoin(location string) error {
	var fullFilePath, fullFileDLURL string

	switch runtime.GOOS {
	case "windows":
		fullFilePath = location + cDownloadFileWin
		fullFileDLURL = cDownloadURL + cDownloadFileWin
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			fullFilePath = location + cDownloadFileArm32
			fullFileDLURL = cDownloadURL + cDownloadFileArm32
		case "arm64":
			fullFilePath = location + cDownloadFileArm64
			fullFileDLURL = cDownloadURL + cDownloadFileArm64
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
	if err := s.unarchiveFile(fullFilePath, location); err != nil {
		return err
	}
	return nil
}

func (s Syscoin) HomeDir() string {
	if runtime.GOOS == "windows" {
		return cHomeDirWin
	} else {
		return cHomeDir
	}
}

func (s Syscoin) HomeDirFullPath() (string, error) {
	u, err := user.Current()
	if err != nil {
		return "", err
	}
	hd := u.HomeDir

	if runtime.GOOS == "windows" {
		return fileutils.AddTrailingSlash(hd) + "appdata\\roaming\\" + fileutils.AddTrailingSlash(cHomeDirWin), nil
	} else {
		return fileutils.AddTrailingSlash(hd) + fileutils.AddTrailingSlash(cHomeDir), nil
	}
}

// Install - Puts the freshly downloaded files into their correct location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (s Syscoin) Install(location string) error {

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
			sfD = cDaemonFileLin
			sfTX = cTxFile
			dirToRemove = location + cExtractedDirLin
		case "amd64":
			srcPath = location + cExtractedDirLin + "bin/"
			sfCLI = cCliFile
			sfD = cDaemonFileLin
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

	_ = os.RemoveAll(dirToRemove)

	return nil
}

func (s Syscoin) ListReceivedByAddress(coinAuth *models.CoinAuth, includeZero bool) (models.SYSListReceivedByAddress, error) {
	var respStruct models.SYSListReceivedByAddress

	var str string
	if includeZero {
		str = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, true]}"
	} else {
		str = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, false]}"
	}
	body := strings.NewReader(str)
	req, err := http.NewRequest("POST", "http://"+coinAuth.IPAddress+":"+coinAuth.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(coinAuth.RPCUser, coinAuth.RPCPassword)
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

func (s Syscoin) ListTransactions(auth *models.CoinAuth) (models.SYSListTransactions, error) {
	var respStruct models.SYSListTransactions

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandListTransactions + "\",\"params\":[]}")
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

	return respStruct, nil
}

func (s Syscoin) NetworkDifficultyInfo() (float64, float64, error) {
	// https://chainz.cryptoid.info/ftc/api.dws?q=getdifficulty

	resp, err := http.Get("https://chainz.cryptoid.info/" + strings.ToLower(s.CoinNameAbbrev()) + "/api.dws?q=getdifficulty")
	if err != nil {
		return 0, 0, err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return 0, 0, err
	}

	var fGood float64
	var fWarning float64
	// Now calculate the correct levels...
	if fDiff, err := strconv.ParseFloat(string(body), 32); err == nil {
		fGood = fDiff * 0.75
		fWarning = fDiff * 0.50
	}
	return fGood, fWarning, nil
}

func (s Syscoin) NewAddress(auth *models.CoinAuth) (models.SYSGetNewAdddress, error) {
	var respStruct models.SYSGetNewAdddress

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getnewaddress\",\"params\":[]}")
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

	return respStruct, nil
}

func (s Syscoin) RPCDefaultUsername() string {
	return cRPCUser
}

func (s Syscoin) RPCDefaultPort() string {
	return cRPCPort
}

func (s Syscoin) SendToAddress(coinAuth *models.CoinAuth, address string, amount float32) (returnResp models.GenericResponse, err error) {
	var respStruct models.GenericResponse

	sAmount := fmt.Sprintf("%f", amount) // sAmount == "123.456000"

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandSendToAddress + "\",\"params\":[\"" + address + "\"," + sAmount + "]}")
	req, err := http.NewRequest("POST", "http://"+coinAuth.IPAddress+":"+coinAuth.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(coinAuth.RPCUser, coinAuth.RPCPassword)
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

func (s Syscoin) StartDaemon(displayOutput bool, appFolder string, auth *models.CoinAuth) error {
	b, _ := s.DaemonRunning()
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

	// Now work out whether we need to create, or load the wallet.

	// Check to see if a "mainwallet" directory exists in ~/.syscoin.

	// If it does, load it, if not, create it.

	wExists, err := s.WalletExists()
	if err != nil {
		return err
	}

	if !wExists {
		// The wallet doesn't exist - When you create it, it's auto loaded
		err := s.WalletCreate(auth)
		if err != nil {
			return err
		}
	}

	wl := s.WalletLoaded(auth)
	if !wl {
		err := s.WalletLoad(auth)
		if err != nil {
			return err
		}
	}

	return nil
}

func (s Syscoin) StopDaemon(auth *models.CoinAuth) error {
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
	//bodyResp, err := ioutil.ReadAll(resp.Body)
	//if err != nil {
	//	return respStruct, err
	//}
	//err = json.Unmarshal(bodyResp, &respStruct)
	//if err != nil {
	//	return respStruct, err
	//}
	return nil
}

func (s Syscoin) TipAddress() string {
	return cTipAddress
}

func (s Syscoin) WalletCreate(auth *models.CoinAuth) error {
	//var respStruct models.SYSCreateWallet

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandCreateWallet + "\",\"params\":[\"" + cWalletName + "\",true]}")
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
	bodyResp, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if bytes.Contains(bodyResp, []byte("Error")) {
		return errors.New("unable to load wallet")
	}

	//err = json.Unmarshal(bodyResp, &respStruct)
	//if err != nil {
	//	return respStruct, err
	//}
	return nil
}

func (s Syscoin) WalletExists() (bool, error) {
	fp, err := s.HomeDirFullPath()
	if err != nil {
		return false, err
	}

	if _, err := os.Stat(fp + cWalletName); os.IsNotExist(err) {
		return false, nil
	}

	return true, nil
}

func (s Syscoin) WalletInfo(auth *models.CoinAuth) (models.SYSWalletInfo, error) {
	var respStruct models.SYSWalletInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetWalletInfo + "\",\"params\":[]}")
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
	return respStruct, nil
}

func (s Syscoin) WalletLoad(auth *models.CoinAuth) error {
	//var respStruct models.SYSLoadWallet

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandLoadWallet + "\",\"params\":[\"" + cWalletName + "\",true]}")
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
	//bodyResp, err := ioutil.ReadAll(resp.Body)
	//if err != nil {
	//	return err
	//}
	//if !bytes.Contains(bodyResp, []byte("\"error\":null")) {
	//	return errors.New("unable to load wallet")
	//}

	//err = json.Unmarshal(bodyResp, &respStruct)
	//if err != nil {
	//	return respStruct, err
	//}
	return nil
}

func (s Syscoin) WalletLoaded(auth *models.CoinAuth) bool {
	wi, _ := s.WalletInfo(auth)
	if wi.Result.Walletversion > 0 {
		return true
	}

	return false
}

func (s *Syscoin) unarchiveFile(fullFilePath, location string) error {
	if err := archiver.Unarchive(fullFilePath, location); err != nil {
		return fmt.Errorf("unable to unarchive file: %v - %v", fullFilePath, err)
	}
	switch runtime.GOOS {
	case "windows":
		defer os.RemoveAll(location + cDownloadFileWin)
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			defer os.RemoveAll(location + cDownloadFileArm32)
		case "arm64":
			defer os.RemoveAll(location + cDownloadFileArm64)
		case "386":
			return errors.New("linux 386 is not currently supported for :" + cCoinName)
		case "amd64":
			defer os.RemoveAll(location + cDownloadFileLin)
		}
	}

	defer os.Remove(fullFilePath)

	return nil
}

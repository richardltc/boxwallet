package navcoin

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
	"time"

	"github.com/mholt/archiver/v3"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/rjminternet"
)

const (
	cCoinName       string = "Navcoin"
	cCoinNameAbbrev string = "NAV"

	cHomeDir    string = ".navcoin4"
	cHomeDirWin string = "NAVCOIN"

	//cCoreVersion string = "7.0.1"
	//cDownloadFileArm32          = "navcoin-" + cCoreVersion + "-RPi2.tar.gz"
	//cDownloadFileLinux          = "divi-" + cCoreVersion + "-x86_64-linux.tar.gz"
	//cDownloadFileWindows        = "divi-" + cCoreVersion + "-win64.zip"
	cDownloadFileBS string = "bootstrap.tar.gz"

	//cExtractedDirLinux = "navcoin-" + cCoreVersion + "/"
	//cExtractedDirWindows = "navcoin-" + cCoreVersion + "\\"

	cAPIURL string = "https://api.github.com/repos/navcoin/navcoin-core/releases/latest"
	//cDownloadURL          = "https://github.com/DiviProject/Divi/releases/download/v" + cCoreVersion + "/"
	cDownloadURLBS string = "https://bootstrap.nav.community/"

	cConfFile      string = "navcoin.conf"
	cCliFileLin    string = "navcoin-cli"
	cCliFileWin    string = "navcoin-cli.exe"
	cDaemonFileLin string = "navcoind"
	cDaemonFileWin string = "navcoind.exe"
	cTxFile        string = "navcoin-tx"
	cTxFileWin     string = "navcoin-tx.exe"

	// divi.conf file constants
	cRPCUser string = "navcoinrpc"
	cRPCPort string = "44444"

	cTipAddress string = "DGvhjUXznuDyALk9zX4Y3ko4QQTmRhF7jZ"

	// Wallet encryption status
	CWalletESUnlockedForStaking = "unlocked-for-staking"
	CWalletESLocked             = "locked"
	CWalletESUnlocked           = "unlocked"
	CWalletESUnencrypted        = "unencrypted"

	// General CLI command constants
	// cCommandGetBCInfo             string = "getblockchaininfo"
	//cCommandGetInfo string = "getinfo"
	// cCommandGetStakingInfo        string = "getstakinginfo"
	// cCommandListReceivedByAddress string = "listreceivedbyaddress"
	// cCommandListTransactions      string = "listtransactions"
	// cCommandGetNetworkInfo        string = "getnetworkinfo"
	// cCommandGetNewAddress         string = "getnewaddress"
	cCommandGetWalletInfo string = "getwalletinfo"
	// cCommandSendToAddress         string = "sendtoaddress"
	// cCommandMNSyncStatus1         string = "mnsync"
	// cCommandMNSyncStatus2         string = "status"
	cCommandDumpHDInfo string = "dumphdinfo" // ./divi-cli dumphdinfo
)

type Navcoin struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

// var gLastBCSyncPos float64 = 0

func (n Navcoin) Bootstrap(rpcUser, rpcPassword, ip, port string) {
	n.RPCUser = rpcUser
	n.RPCPassword = rpcPassword
	n.IPAddress = ip
	if port == "" {
		n.Port = cRPCPort
	} else {
		n.Port = port
	}
}

func (n Navcoin) AbbreviatedCoinName() string {
	return cCoinNameAbbrev
}

func (n Navcoin) addNodesAlreadyExist() (bool, error) {
	var exists bool
	file, err := n.HomeDirFullPath()
	if err != nil {
		return false, err
	}
	file = file + cConfFile

	exists, err = fileutils.StringExistsInFile("addnode=", file)
	if err != nil {
		return false, nil
	}

	if exists {
		return true, nil
	}

	return false, nil
}

func (n Navcoin) AddAddNodesIfRequired() error {
	doExist, err := n.addNodesAlreadyExist()
	if err != nil {
		return err
	}
	if !doExist {
		fullPath, err := n.HomeDirFullPath()
		if err != nil {
			return err
		}
		if err := os.MkdirAll(fullPath, os.ModePerm); err != nil {
			return fmt.Errorf("unable to make directory - %v", err)
		}

		var addnodes []models.DiviAddNodes
		var sAddnodes string

		addnodes, err = n.getNavcoinAddNodes()
		if err != nil {
			return fmt.Errorf("unable to getDiviAddNodes - %v", err)
		}

		if err := fileutils.WriteTextToFile(fullPath+cConfFile, sAddnodes); err != nil {
			return fmt.Errorf("unable to write addnodes to file - %v", err)
		}

		for _, addnode := range addnodes {
			for _, node := range addnode.Nodes {
				// Build up sAddnodes to contain every IP address that's been found...
				sAddnodes = sAddnodes + "addnode=" + node + "\n"
			}
			//sAddnodes = sAddnodes + addnode.Nodes
		}

		// If sAddnodes doesn't contain the string "addnode" then...
		if !strings.Contains(sAddnodes, "addnode") {
			return fmt.Errorf("unable to retrieve addnodes, please try again")
		}

		if err := fileutils.WriteTextToFile(fullPath+cConfFile, sAddnodes); err != nil {
			return fmt.Errorf("unable to write addnodes to file - %v", err)
		}

	}

	return nil
}

func (n Navcoin) AllBinaryFilesExist(dir string) (bool, error) {
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
		if !fileutils.FileExists(dir + cCliFileLin) {
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

func (n Navcoin) AnyAddresses(auth *models.CoinAuth) (bool, error) {
	addresses, err := n.ListReceivedByAddress(auth, false)
	if err != nil {
		return false, err
	}
	if len(addresses.Result) > 0 {
		return true, nil
	}

	return false, nil
}

func (n Navcoin) BackupCoreFiles(dir string) error {
	if err := fileutils.BackupFile(dir, cDaemonFileLin, dir, "", true); err != nil {
		return err
	}
	if err := fileutils.BackupFile(dir, cCliFileLin, dir, "", true); err != nil {
		return err
	}
	if err := fileutils.BackupFile(dir, cTxFile, dir, "", true); err != nil {
		return err
	}

	return nil
}

// BlockchainDataExists - Returns true if the Blockchain data exists for the specified coin
func (n Navcoin) BlockchainDataExists() (bool, error) {
	coinDir, err := n.HomeDirFullPath()
	if err != nil {
		return false, errors.New("unable to HomeDirFullPath - BlockchainDataExists")
	}

	// If the "blocks" directory already exists, return.
	if _, err := os.Stat(coinDir + "blocks"); !os.IsNotExist(err) {
		err := errors.New("The directory: " + coinDir + "blocks already exists")
		return true, err
	}

	// If the "chainstate" directory already exists, return
	if _, err := os.Stat(coinDir + "chainstate"); !os.IsNotExist(err) {
		err := errors.New("The directory: " + coinDir + "chainstate already exists")
		return true, err
	}

	return false, nil
}

func (n Navcoin) BlockchainInfo(auth *models.CoinAuth) (models.NAVBlockchainInfo, error) {
	var respStruct models.NAVBlockchainInfo

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

func (n Navcoin) BlockchainIsSynced(coinAuth *models.CoinAuth) (bool, error) {
	bci, err := n.BlockchainInfo(coinAuth)
	if err != nil {
		return false, err
	}

	if bci.Result.Verificationprogress > 0.99999 {
		return true, nil
	}

	return false, nil
}

func (n Navcoin) ConfFile() string {
	return cConfFile
}

func (n Navcoin) CoinName() string {
	return cCoinName
}

func (n Navcoin) CoinNameAbbrev() string {
	return cCoinNameAbbrev
}

func (n Navcoin) DaemonFilename() string {
	if runtime.GOOS == "windows" {
		return cDaemonFileWin
	}

	return cDaemonFileLin
}

func (n Navcoin) DaemonRunning() (bool, error) {
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

func (n Navcoin) DownloadBlockchain() error {
	coinDir, err := n.HomeDirFullPath()
	if err != nil {
		return errors.New("unable to get HomeDirFullPath: " + err.Error())
	}
	bcsFileExists := fileutils.FileExists(coinDir + cDownloadFileBS)
	if !bcsFileExists {
		// Then download the file.
		if err := rjminternet.DownloadFile(coinDir, cDownloadURLBS+cDownloadFileBS); err != nil {
			return fmt.Errorf("unable to download file: %v - %v", cDownloadURLBS, err)
		}
	}

	return nil
}

// DownloadCoin - Downloads the Syscoin files into the spcified location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (n Navcoin) DownloadCoin(location string) error {
	var fullFilePath string
	ghInfo, err := latestAssets()
	if err != nil {
		return err
	}

	downloadFile, err := latestDownloadFile(&ghInfo)
	if err != nil {
		return err
	}

	fullFileDLURL, err := latestDownloadFileURL(&ghInfo)
	if err != nil {
		return err
	}

	fullFilePath = location + downloadFile

	if err := rjminternet.DownloadFile(fullFilePath, fullFileDLURL); err != nil {
		return fmt.Errorf("unable to download file: %v - %v", fullFilePath+fullFileDLURL, err)
	}

	// Unarchive the files
	if err := n.unarchiveFile(fullFilePath, location, downloadFile); err != nil {
		return err
	}

	return nil
}

func (n Navcoin) extractedDir() (string, error) {
	ghInfo, err := latestAssets()
	if err != nil {
		return "", err
	}

	var s string
	switch runtime.GOOS {
	case "windows":
		s = strings.ToLower(cCoinName) + "-" + ghInfo.TagName + "\\"
	case "linux":
		s = strings.ToLower(cCoinName) + "-" + ghInfo.TagName + "/"
	default:
		return "", errors.New("unable to determine runtime.GOOS")
	}

	return s, nil
}

func (n Navcoin) HomeDir() string {
	if runtime.GOOS == "windows" {
		return cHomeDirWin
	} else {
		return cHomeDir
	}
}

func (n Navcoin) HomeDirFullPath() (string, error) {
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

func (n Navcoin) Info(auth *models.CoinAuth) (models.NAVGetInfo, string, error) {
	var respStruct models.NAVGetInfo

	for i := 1; i < 50; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getinfo\",\"params\":[]}")
		req, err := http.NewRequest("POST", "http://"+auth.IPAddress+":"+auth.Port, body)
		if err != nil {
			return respStruct, "", err
		}
		req.SetBasicAuth(auth.RPCUser, auth.RPCPassword)
		req.Header.Set("Content-Type", "text/plain;")

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return respStruct, "", err
		}
		defer resp.Body.Close()
		bodyResp, err := ioutil.ReadAll(resp.Body)
		if err != nil {
			return respStruct, "", err
		}

		// Check to make sure we are not loading the wallet
		if bytes.Contains(bodyResp, []byte("Loading")) ||
			bytes.Contains(bodyResp, []byte("Rewinding")) ||
			bytes.Contains(bodyResp, []byte("Verifying")) {
			// The wallet is still loading, so print message, and sleep for 3 seconds and try again..
			var errStruct models.GenericResponse
			err = json.Unmarshal(bodyResp, &errStruct)
			if err != nil {
				return respStruct, "", err
			}
			//fmt.Println("Waiting for wallet to load...")
			time.Sleep(5 * time.Second)
		} else {

			_ = json.Unmarshal(bodyResp, &respStruct)
			return respStruct, string(bodyResp), err
		}
	}

	return respStruct, "", nil
}

// Install - Puts the freshly downloaded files into their correct location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (n Navcoin) Install(location string) error {

	// Copy files to correct location
	var srcPath, sfCLI, sfD, sfTX, dirToRemove string

	extractedDir, _ := n.extractedDir()
	switch runtime.GOOS {
	case "windows":
		srcPath = location + extractedDir
		sfCLI = cCliFileWin
		sfD = cDaemonFileWin
		sfTX = cTxFileWin
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			srcPath = location + extractedDir + "bin/"
			sfCLI = cCliFileLin
			sfD = cDaemonFileLin
			sfTX = cTxFile
			dirToRemove = location + extractedDir
		case "arm64":
			return errors.New("arm64 is not currently supported by " + cCoinName)
		case "amd64":
			srcPath = location + extractedDir + "bin/"
			sfCLI = cCliFileLin
			sfD = cDaemonFileLin
			sfTX = cTxFile
			dirToRemove = location + extractedDir
		default:
			return errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
		}
	default:
		return errors.New("unable to determine runtime.GOOS")
	}

	// If the coin-cli file doesn't already exist the copy it.
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

func (n Navcoin) IsPOS() bool {
	return true
}

// func GetBalanceInCurrencyTxtDivi(currency string, wi *DiviWalletInfoRespStruct) string {
// 	tBalance := wi.Result.ImmatureBalance + wi.Result.UnconfirmedBalance + wi.Result.Balance
// 	var pricePerCoin float64
// 	var symbol string

// 	// Work out what currency
// 	switch currency {
// 	case "AUD":
// 		symbol = "$"
// 		pricePerCoin = gTicker.DIVI.Quote.USD.Price * gPricePerCoinAUD.Rates.AUD
// 	case "USD":
// 		symbol = "$"
// 		pricePerCoin = gTicker.DIVI.Quote.USD.Price
// 	case "GBP":
// 		symbol = "£"
// 		pricePerCoin = gTicker.DIVI.Quote.USD.Price * gPricePerCoinGBP.Rates.GBP
// 	default:
// 		symbol = "$"
// 		pricePerCoin = gTicker.DIVI.Quote.USD.Price
// 	}

// 	tBalanceCurrency := pricePerCoin * tBalance

// 	tBalanceCurrencyStr := humanize.FormatFloat("###,###.##", tBalanceCurrency) //humanize.Commaf(tBalanceCurrency) //FormatFloat("#,###.####", tBalanceCurrency)

// 	// Work out balance
// 	if wi.Result.ImmatureBalance > 0 {
// 		return "Incoming......... [" + symbol + tBalanceCurrencyStr + "](fg:cyan)"
// 	} else if wi.Result.UnconfirmedBalance > 0 {
// 		return "Confirming....... [" + symbol + tBalanceCurrencyStr + "](fg:yellow)"
// 	} else {
// 		return "Currency:         [" + symbol + tBalanceCurrencyStr + "](fg:green)"
// 	}
// }

func (n Navcoin) getNavcoinAddNodes() (addnodes []models.DiviAddNodes, err error) {
	resp, err := http.Get("https://chainz.cryptoid.info/" + strings.ToLower(n.CoinNameAbbrev()) + "/api.dws?q=nodes")
	if err != nil {
		return addnodes, err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return addnodes, err
	}
	if bytes.Contains(body, []byte("Error")) {
		return addnodes, errors.New("error response from api")
	}

	err = json.Unmarshal(body, &addnodes)
	if err != nil {
		return addnodes, err
	}

	return addnodes, nil
}

func (n Navcoin) DumpHDInfo(coinAuth *models.CoinAuth, pw string) (string, error) {
	var respStruct models.DiviDumpHDInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandDumpHDInfo + "\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+coinAuth.IPAddress+":"+coinAuth.Port, body)
	if err != nil {
		return "", err
	}
	req.SetBasicAuth(coinAuth.RPCUser, coinAuth.RPCPassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	bodyResp, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	err = json.Unmarshal(bodyResp, &respStruct)
	if err != nil {
		return "", err
	}

	return respStruct.Result.Mnemonic, nil
}

func archStrToFile(arch string, ghInfo *models.GithubInfo) (fileName string) {
	for _, a := range ghInfo.Assets {
		if strings.Contains(a.Name, arch) {
			return a.Name
		}
	}

	return ""
}

func archStrToFileDownloadURL(arch string, ghInfo *models.GithubInfo) string {
	for _, a := range ghInfo.Assets {
		if strings.Contains(a.BrowserDownloadURL, arch) {
			return a.BrowserDownloadURL
		}
	}

	return ""
}

func latestDownloadFile(ghInfo *models.GithubInfo) (string, error) {
	var sFile string
	switch runtime.GOOS {
	case "windows":
		sFile = archStrToFile("win64", ghInfo)
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			sFile = archStrToFile("arm", ghInfo)
		case "arm64":
			sFile = archStrToFile("aarch64", ghInfo)
		case "386":
			return "", errors.New("linux 386 is not currently supported for :" + cCoinName)
		case "amd64":
			sFile = archStrToFile("x86_64", ghInfo)
		}
	}

	if sFile == "" {
		return "", errors.New("unable to determine download url - latestDownloadFileURL")
	}

	return sFile, nil
}

func latestDownloadFileURL(ghInfo *models.GithubInfo) (string, error) {
	//ghInfo, err := latestAssets()
	//if err != nil {
	//	return "", err
	//}
	//
	var sURL string
	switch runtime.GOOS {
	case "windows":
		sURL = archStrToFileDownloadURL("win64", ghInfo)
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			sURL = archStrToFileDownloadURL("arm", ghInfo)
		case "arm64":
			sURL = archStrToFileDownloadURL("aarch64", ghInfo)
		case "386":
			return "", errors.New("linux 386 is not currently supported for :" + cCoinName)
		case "amd64":
			sURL = archStrToFileDownloadURL("x86_64", ghInfo)
		}
	}

	if sURL == "" {
		return "", errors.New("unable to determine download url - latestDownloadFileURL")
	}

	return sURL, nil
}

func latestAssets() (models.GithubInfo, error) {
	var ghInfo models.GithubInfo

	resp, err := http.Get(cAPIURL)
	if err != nil {
		return ghInfo, err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return ghInfo, err
	}
	err = json.Unmarshal(body, &ghInfo)
	if err != nil {
		return ghInfo, err
	}

	return ghInfo, nil
}

func (n Navcoin) ListReceivedByAddress(coinAuth *models.CoinAuth, includeZero bool) (models.NAVListReceivedByAddress, error) {
	var respStruct models.NAVListReceivedByAddress

	var s string
	if includeZero {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, true]}"
	} else {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, false]}"
	}
	body := strings.NewReader(s)
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

func (n Navcoin) ListTransactions(auth *models.CoinAuth) (models.NAVListTransactions, error) {
	var respStruct models.NAVListTransactions

	//body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandListTransactions + "\",\"params\":[]}")
	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandListTransactions + "\",\"params\":[\"*\",25,0]}")
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

//func (n *Navcoin) MNSyncStatus(auth *models.CoinAuth) (models.DiviMNSyncStatus, error) {
//	var respStruct models.DiviMNSyncStatus
//
//	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"mnsync\",\"params\":[\"status\"]}")
//	req, err := http.NewRequest("POST", "http://"+auth.IPAddress+":"+auth.Port, body)
//	if err != nil {
//		return respStruct, err
//	}
//	req.SetBasicAuth(auth.RPCUser, auth.RPCPassword)
//	req.Header.Set("Content-Type", "text/plain;")
//
//	resp, err := http.DefaultClient.Do(req)
//	if err != nil {
//		return respStruct, err
//	}
//	defer resp.Body.Close()
//	bodyResp, err := ioutil.ReadAll(resp.Body)
//	if err != nil {
//		return respStruct, err
//	}
//	err = json.Unmarshal(bodyResp, &respStruct)
//	if err != nil {
//		return respStruct, err
//	}
//
//	return respStruct, nil
//}

func (n Navcoin) NetworkDifficultyInfo() (float64, float64, error) {
	// https://chainz.cryptoid.info/ftc/api.dws?q=getdifficulty

	resp, err := http.Get("https://chainz.cryptoid.info/" + strings.ToLower(n.CoinName()) + "/api.dws?q=getdifficulty")
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

func (n Navcoin) NewAddress(auth *models.CoinAuth) (models.NAVGetNewAddress, error) {
	var respStruct models.NAVGetNewAddress

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

// RemoveBlockchainData - Returns true if the Blockchain data exists for the specified coin
func (n Navcoin) RemoveBlockchainData() error {
	coinDir, err := n.HomeDirFullPath()
	if err != nil {
		return errors.New("unable to HomeDirFullPath - RemoveBlockchainData")
	}

	// If the "blocks" directory exists, remove it.
	if err := os.RemoveAll(coinDir + "blocks"); err != nil {
		return err
	}

	// If the "chainstate" directory exists, remove it
	if err := os.RemoveAll(coinDir + "chainstate"); err != nil {
		return err
	}

	return nil
}

func (n Navcoin) RemoveCoreFiles(dir string) error {
	srcFolder := fileutils.AddTrailingSlash(dir)

	if err := os.Remove(srcFolder + cDaemonFileLin); err != nil {
		return err
	}
	if err := os.Remove(srcFolder + cCliFileLin); err != nil {
		return err
	}
	if err := os.Remove(srcFolder + cTxFile); err != nil {
		return err
	}

	return nil
}

func (n Navcoin) RPCDefaultUsername() string {
	return cRPCUser
}

func (n Navcoin) RPCDefaultPort() string {
	return cRPCPort
}

func (n Navcoin) StakingStatus(auth *models.CoinAuth) (models.DiviStakingStatus, error) {
	var respStruct models.DiviStakingStatus

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getstakingstatus\",\"params\":[]}")
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

func (n Navcoin) SendToAddress(coinAuth *models.CoinAuth, address string, amount float32) (returnResp models.GenericResponse, err error) {
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

func (n Navcoin) StartDaemon(displayOutput bool, appFolder string) error {
	b, _ := n.DaemonRunning()
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

func (n Navcoin) StopDaemon(auth *models.CoinAuth) error {
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
	//	return err
	//}
	//err = json.Unmarshal(bodyResp, &respStruct)
	//if err != nil {
	//	return err
	//}

	return nil
}

func (n Navcoin) TipAddress() string {
	return cTipAddress
}

func (n Navcoin) ValidateAddress(ad string) bool {
	// First, work out what the coin type is
	// If the length of the address is not exactly 34 characters...
	if len(ad) != 34 {
		return false
	}
	sFirst := ad[0]

	// todo Change for N?
	// 68 = UTF for D
	if sFirst != 68 {
		return false
	}

	return true
}

func (n Navcoin) UnarchiveBlockchainSnapshot() error {
	coinDir, err := n.HomeDirFullPath()
	if err != nil {
		return errors.New("unable to get HomeDirFul - " + err.Error())
	}

	// First, check to make sure that both the blockchain folders don't already exist. (blocks, chainstate)
	bcsFileExists := fileutils.FileExists(coinDir + cDownloadFileBS)
	if !bcsFileExists {
		return errors.New("unable to find the snapshot file: " + coinDir + cDownloadFileBS)
	}

	// Now extract it straight into the ~/.divi folder
	if err := archiver.Unarchive(coinDir+cDownloadFileBS, coinDir); err != nil {
		return errors.New("unable to unarchive file: " + coinDir + cDownloadFileBS + " " + err.Error())
	}

	return nil
}

func (n Navcoin) UpdateTickerInfo() (ticker models.DiviTicker, err error) {
	resp, err := http.Get("https://ticker.neist.io/DIVI")
	if err != nil {
		return ticker, err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return ticker, err
	}
	err = json.Unmarshal(body, &ticker)
	if err != nil {
		return ticker, err
	}

	return ticker, nil
}

func (n *Navcoin) unarchiveFile(fullFilePath, location, downloadFile string) error {
	if err := archiver.Unarchive(fullFilePath, location); err != nil {
		return fmt.Errorf("unable to unarchive file: %v - %v", fullFilePath, err)
	}
	//switch runtime.GOOS {
	//case "windows":
	//	defer os.RemoveAll(location + cDownloadFileWindows)
	//case "linux":
	//	switch runtime.GOARCH {
	//	case "arm":
	//		defer os.RemoveAll(location + cDownloadFileArm32)
	//	case "arm64":
	//		return errors.New("arm64 is not currently supported for :" + cCoinName)
	//	case "386":
	//		return errors.New("linux 386 is not currently supported for :" + cCoinName)
	//	case "amd64":
	//		defer os.RemoveAll(location + cDownloadFileLinux)
	//	}
	//}

	defer os.RemoveAll(location + downloadFile)

	defer os.Remove(fullFilePath)

	return nil
}

func (n Navcoin) WalletAddress(auth *models.CoinAuth) (string, error) {
	var sAddress string
	addresses, _ := n.ListReceivedByAddress(auth, true)
	if len(addresses.Result) > 0 {
		sAddress = addresses.Result[0].Address
	} else {
		r, err := n.NewAddress(auth)
		if err != nil {
			return "", err
		}
		sAddress = r.Result
	}

	return sAddress, nil
}

func (n Navcoin) WalletBackup(coinAuth *models.CoinAuth, destDir string) (models.GenericResponse, error) {
	var respStruct models.GenericResponse

	destDir = fileutils.AddTrailingSlash(destDir)
	dt := time.Now()
	destFile := dt.Format("2006-01-02") + "-" + cCoinNameAbbrev + "-wallet.dat"

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandBackupWallet + "\",\"params\":[\"" + destDir + destFile + "\"]}")

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

	if respStruct.Error != nil {
		return respStruct, errors.New(fmt.Sprintf("%v", respStruct.Error))
	}

	return respStruct, nil
}

func (n Navcoin) WalletEncrypt(coinAuth *models.CoinAuth, pw string) (models.GenericResponse, error) {
	var respStruct models.GenericResponse

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandEncryptWallet + "\",\"params\":[\"" + pw + "\"]}")
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

//func (n Navcoin) WalletInfo(auth *models.CoinAuth) (models.DiviWalletInfo, error) {
//	var respStruct models.DiviWalletInfo
//
//	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetWalletInfo + "\",\"params\":[]}")
//	req, err := http.NewRequest("POST", "http://"+auth.IPAddress+":"+auth.Port, body)
//	if err != nil {
//		return respStruct, err
//	}
//	req.SetBasicAuth(auth.RPCUser, auth.RPCPassword)
//	req.Header.Set("Content-Type", "text/plain;")
//
//	resp, err := http.DefaultClient.Do(req)
//	if err != nil {
//		return respStruct, err
//	}
//	defer resp.Body.Close()
//	bodyResp, err := ioutil.ReadAll(resp.Body)
//	if err != nil {
//		return respStruct, err
//	}
//	err = json.Unmarshal(bodyResp, &respStruct)
//	if err != nil {
//		return respStruct, err
//	}
//
//	return respStruct, nil
//}

func (n Navcoin) WalletLoadingStatus(auth *models.CoinAuth) models.WLSType {
	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetInfo + "\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+auth.IPAddress+":"+auth.Port, body)
	if err != nil {
		return models.WLSTUnknown
	}
	req.SetBasicAuth(auth.RPCUser, auth.RPCPassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return models.WLSTWaitingForResponse
	} else {
		defer resp.Body.Close()
		bodyResp, err := ioutil.ReadAll(resp.Body)
		if err != nil {
			return models.WLSTWaitingForResponse
		}

		if bytes.Contains(bodyResp, []byte("Loading")) {
			return models.WLSTLoading
		}
		if bytes.Contains(bodyResp, []byte("Rescanning")) {
			return models.WLSTRescanning
		}
		if bytes.Contains(bodyResp, []byte("Rewinding")) {
			return models.WLSTRewinding
		}
		if bytes.Contains(bodyResp, []byte("Verifying")) {
			return models.WLSTVerifying
		}
		if bytes.Contains(bodyResp, []byte("Calculating money supply")) {
			return models.WLSTCalculatingMoneySupply
		}
	}

	return models.WLSTReady
}

func (n Navcoin) WalletNeedsEncrypting(coinAuth *models.CoinAuth) (bool, error) {
	wi, _, err := n.Info(coinAuth)
	if err != nil {
		return true, errors.New("Unable to perform WalletInfo " + err.Error())
	}

	if wi.Result.UnlockedUntil < 0 {
		return true, nil
	}

	return false, nil
}

func (n Navcoin) WalletResync(appFolder string) error {
	daemonRunning, err := n.DaemonRunning()
	if err != nil {
		return errors.New("Unable to determine DaemonRunning: " + err.Error())
	}
	if daemonRunning {
		return errors.New("daemon is still running, please stop first")
	}

	arg1 := "-resync"

	if runtime.GOOS == "windows" {
		fullPath := appFolder + cDaemonFileWin
		cmd := exec.Command("cmd.exe", "/C", "start", "/b", fullPath, arg1)
		if err := cmd.Run(); err != nil {
			return err
		}
	} else {
		fullPath := appFolder + cDaemonFileLin
		cmdRun := exec.Command(fullPath, arg1)
		if err := cmdRun.Run(); err != nil {
			return err
		}
	}

	return nil
}

func (n Navcoin) WalletSecurityState(coinAuth *models.CoinAuth) (models.WEType, error) {
	wi, _, err := n.Info(coinAuth)
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

func (n Navcoin) WalletUnlock(coinAuth *models.CoinAuth, pw string) error {
	var respStruct models.GenericResponse

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",0]}")
	req, err := http.NewRequest("POST", "http://"+coinAuth.IPAddress+":"+coinAuth.Port, body)
	if err != nil {
		return err
	}
	req.SetBasicAuth(coinAuth.RPCUser, coinAuth.RPCPassword)
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

	if respStruct.Error != nil {
		return errors.New(fmt.Sprintf("%v", respStruct.Error))
	}

	return nil
}

func (n Navcoin) WalletUnlockFS(coinAuth *models.CoinAuth, pw string) error {
	var respStruct models.GenericResponse
	var body *strings.Reader

	body = strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",9999999,true]}")

	req, err := http.NewRequest("POST", "http://"+coinAuth.IPAddress+":"+coinAuth.Port, body)
	if err != nil {
		return err
	}
	req.SetBasicAuth(coinAuth.RPCUser, coinAuth.RPCPassword)
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

	if respStruct.Error != nil {
		return errors.New(fmt.Sprintf("%v", respStruct.Error))
	}

	return nil
}

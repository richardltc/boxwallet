package divi

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
	"github.com/theckman/yacspin"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/rjminternet"
)

const (
	cAddNodeURL string = "https://api.diviproject.org/v1/addnode"

	cCoinName       string = "DIVI"
	cCoinNameAbbrev string = "DIVI"

	cHomeDir    string = ".divi"
	cHomeDirWin string = "DIVI"

	cCoreVersion         string = "2.5.1"
	cDownloadFileArm32          = "divi-" + cCoreVersion + "-RPi2.tar.gz"
	cDownloadFileLinux          = "divi-" + cCoreVersion + "-x86_64-linux.tar.gz"
	cDownloadFileWindows        = "divi-" + cCoreVersion + "-win64.zip"
	cDownloadFileBS      string = "DIVI-snapshot.zip"

	cExtractedDirLinux = "divi-" + cCoreVersion + "/"
	// cExtractedDirWindows = "divi-" + cCoreVersion + "\\"

	cDownloadURL          = "https://github.com/DiviProject/Divi/releases/download/v" + cCoreVersion + "/"
	cDownloadURLBS string = "https://snapshots.diviproject.org/dist/"

	cConfFile      string = "divi.conf"
	cCliFileLin    string = "divi-cli"
	cCliFileWin    string = "divi-cli.exe"
	cDaemonFileLin string = "divid"
	cDaemonFileWin string = "divid.exe"
	cTxFile        string = "divi-tx"
	cTxFileWin     string = "divi-tx.exe"

	// divi.conf file constants
	cRPCUser string = "divirpc"
	cRPCPort string = "51473"

	cTipAddress string = "DGvhjUXznuDyALk9zX4Y3ko4QQTmRhF7jZ"

	// Wallet encryption status
	CWalletESUnlockedForStaking = "unlocked-for-staking"
	CWalletESLocked             = "locked"
	CWalletESUnlocked           = "unlocked"
	CWalletESUnencrypted        = "unencrypted"

	// General CLI command constants
	// cCommandGetBCInfo             string = "getblockchaininfo"
	cCommandGetInfo string = "getinfo"
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

type Divi struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

// var gLastBCSyncPos float64 = 0

func (d Divi) Bootstrap(rpcUser, rpcPassword, ip, port string) {
	d.RPCUser = rpcUser
	d.RPCPassword = rpcPassword
	d.IPAddress = ip
	if port == "" {
		d.Port = cRPCPort
	} else {
		d.Port = port
	}
}

func (d Divi) AbbreviatedCoinName() string {
	return cCoinNameAbbrev
}

func (d Divi) addNodesAlreadyExist() (bool, error) {
	var exists bool
	file, err := d.HomeDirFullPath()
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

func (d Divi) AddAddNodesIfRequired() error {
	doExist, err := d.addNodesAlreadyExist()
	if err != nil {
		return err
	}
	if !doExist {
		fullPath, err := d.HomeDirFullPath()
		if err != nil {
			return err
		}
		if err := os.MkdirAll(fullPath, os.ModePerm); err != nil {
			return fmt.Errorf("unable to make directory - %v", err)
		}

		var addnodes []models.DiviAddNodes
		var sAddnodes string

		addnodes, err = d.getDiviAddNodes()
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

func (d Divi) AllBinaryFilesExist(dir string) (bool, error) {
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

func (d Divi) AnyAddresses(auth *models.CoinAuth) (bool, error) {
	addresses, err := d.ListReceivedByAddress(auth, false)
	if err != nil {
		return false, err
	}
	if len(addresses.Result) > 0 {
		return true, nil
	}

	return false, nil
}

func (d Divi) BackupCoreFiles(dir string) error {
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
func (d Divi) BlockchainDataExists() (bool, error) {
	coinDir, err := d.HomeDirFullPath()
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

func (d Divi) BlockchainInfo(auth *models.CoinAuth) (models.DiviBlockchainInfo, error) {
	var respStruct models.DiviBlockchainInfo

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

func (d Divi) BlockchainIsSynced(coinAuth *models.CoinAuth) (bool, error) {
	bci, err := d.BlockchainInfo(coinAuth)
	if err != nil {
		return false, err
	}

	if bci.Result.Verificationprogress > 0.99999 {
		return true, nil
	}

	return false, nil
}

func (d Divi) ConfFile() string {
	return cConfFile
}

func (d Divi) CoinName() string {
	return cCoinName
}

func (d Divi) CoinNameAbbrev() string {
	return cCoinNameAbbrev
}

func (d Divi) DaemonFilename() string {
	if runtime.GOOS == "windows" {
		return cDaemonFileWin
	}

	return cDaemonFileLin
}

func (d Divi) DaemonRunning() (bool, error) {
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

func (d Divi) DownloadBlockchain() error {
	coinDir, err := d.HomeDirFullPath()
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
func (d Divi) DownloadCoin(location string) error {
	var fullFilePath, fullFileDLURL string

	switch runtime.GOOS {
	case "windows":
		fullFilePath = location + cDownloadFileWindows
		fullFileDLURL = cDownloadURL + cDownloadFileWindows
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			fullFilePath = location + cDownloadFileArm32
			fullFileDLURL = cDownloadURL + cDownloadFileArm32
		case "arm64":
			return errors.New("arm64 is not currently supported for :" + cCoinName)
		case "386":
			return errors.New("linux 386 is not currently supported for :" + cCoinName)
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

func (d Divi) HomeDir() string {
	if runtime.GOOS == "windows" {
		return cHomeDirWin
	} else {
		return cHomeDir
	}
}

func (d Divi) HomeDirFullPath() (string, error) {
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

func (d Divi) Info(auth *models.CoinAuth) (models.DiviGetInfo, string, error) {
	var respStruct models.DiviGetInfo

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
func (d Divi) Install(location string) error {

	// Copy files to correct location
	var srcPath, sfCLI, sfD, sfTX, dirToRemove string

	switch runtime.GOOS {
	case "windows":
		srcPath = location + cDownloadFileWindows
		sfCLI = cCliFileWin
		sfD = cDaemonFileWin
		sfTX = cTxFileWin
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			srcPath = location + cExtractedDirLinux + "bin/"
			sfCLI = cCliFileLin
			sfD = cDaemonFileLin
			sfTX = cTxFile
			dirToRemove = location + cExtractedDirLinux
		case "arm64":
			return errors.New("arm64 is not currently supported by " + cCoinName)
		case "amd64":
			srcPath = location + cExtractedDirLinux + "bin/"
			sfCLI = cCliFileLin
			sfD = cDaemonFileLin
			sfTX = cTxFile
			dirToRemove = location + cExtractedDirLinux
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

func (d Divi) IsPOS() bool {
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

//func GetBlockchainSyncTxtDivi(synced bool, bci *DiviBlockchainInfoRespStruct) string {
//	s := ConvertBCVerification(bci.Result.Verificationprogress)
//	if s == "0.0" {
//		s = ""
//	} else {
//		s = s + "%"
//	}
//
//	if !synced {
//		return "Blockchain: [" + getNextProgBCIndicator(gLastBCSyncStatus) + "syncing " + sProg + " ](fg:yellow)"
//		if bci.Result.Verificationprogress > gLastBCSyncPos {
//			gLastBCSyncPos = bci.Result.Verificationprogress
//			return "Blockchain:  [syncing " + s + " ](fg:yellow)"
//		} else {
//			gLastBCSyncPos = bci.Result.Verificationprogress
//			return "Blockchain:  [waiting " + s + " ](fg:yellow)"
//		}
//	} else {
//		return "Blockchain:  [synced " + CUtfTickBold + "](fg:green)"
//	}
//}

func getDiviAddNodesOld() ([]byte, error) {
	addNodesClient := http.Client{
		Timeout: time.Second * 3, // Maximum of 3 secs.
	}

	req, err := http.NewRequest(http.MethodGet, cAddNodeURL, nil)
	if err != nil {
		return nil, err
	}

	req.Header.Set("User-Agent", "boxwallet")

	res, getErr := addNodesClient.Do(req)
	if getErr != nil {
		return nil, err
	}

	body, readErr := ioutil.ReadAll(res.Body)
	if readErr != nil {
		return nil, err
	}

	return body, nil
}

func (d Divi) getDiviAddNodes() (addnodes []models.DiviAddNodes, err error) {
	//var aNodes []models.DiviAddNodes

	resp, err := http.Get("https://chainz.cryptoid.info/" + strings.ToLower(d.CoinNameAbbrev()) + "/api.dws?q=nodes")
	if err != nil {
		return addnodes, err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return addnodes, err
	}
	err = json.Unmarshal(body, &addnodes)
	if err != nil {
		return addnodes, err
	}

	return addnodes, nil
}

func (d Divi) DumpHDInfo(coinAuth *models.CoinAuth, pw string) (string, error) {
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

func (d *Divi) InfoUI(spin *yacspin.Spinner) (models.DiviGetInfo, string, error) {
	var respStruct models.DiviGetInfo

	for i := 1; i < 600; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetInfo + "\",\"params\":[]}")
		req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
		if err != nil {
			return respStruct, "", err
		}
		req.SetBasicAuth(d.RPCUser, d.RPCPassword)
		req.Header.Set("Content-Type", "text/plain;")

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			spin.Message(" waiting for your " + cCoinName + " wallet to respond, this could take several minutes (ctrl-c to cancel)...")
			time.Sleep(1 * time.Second)
		} else {
			defer resp.Body.Close()
			bodyResp, err := ioutil.ReadAll(resp.Body)
			if err != nil {
				return respStruct, "", err
			}

			// Check to make sure we are not loading the wallet
			if bytes.Contains(bodyResp, []byte("Loading")) ||
				bytes.Contains(bodyResp, []byte("Rescanning")) ||
				bytes.Contains(bodyResp, []byte("Rewinding")) ||
				bytes.Contains(bodyResp, []byte("RPC in warm-up: Calculating money supply")) ||
				bytes.Contains(bodyResp, []byte("Verifying")) {
				// The wallet is still loading, so print message, and sleep for 1 second and try again..
				var errStruct models.GenericResponse
				err = json.Unmarshal(bodyResp, &errStruct)
				if err != nil {
					return respStruct, "", err
				}

				if bytes.Contains(bodyResp, []byte("Loading")) {
					spin.Message(" Your " + cCoinName + " wallet is *Loading*, this could take a while...")
				} else if bytes.Contains(bodyResp, []byte("Rescanning")) {
					spin.Message(" Your " + cCoinName + " wallet is *Rescanning*, this could take a while...")
				} else if bytes.Contains(bodyResp, []byte("Rewinding")) {
					spin.Message(" Your " + cCoinName + " wallet is *Rewinding*, this could take a while...")
				} else if bytes.Contains(bodyResp, []byte("Verifying")) {
					spin.Message(" Your " + cCoinName + " wallet is *Verifying*, this could take a while...")
				} else if bytes.Contains(bodyResp, []byte("Calculating money supply")) {
					spin.Message(" Your " + cCoinName + " wallet is *Calculating money supply*, this could take a while...")
				}
				time.Sleep(1 * time.Second)
			} else {
				_ = json.Unmarshal(bodyResp, &respStruct)
				return respStruct, string(bodyResp), err
			}
		}
	}

	return respStruct, "", nil
}

func (d Divi) ListReceivedByAddress(coinAuth *models.CoinAuth, includeZero bool) (models.DiviListReceivedByAddress, error) {
	var respStruct models.DiviListReceivedByAddress

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

func (d Divi) ListTransactions(auth *models.CoinAuth) (models.DiviListTransactions, error) {
	var respStruct models.DiviListTransactions

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

//func (d Divi) LotteryInfo() (models.DiviLottery, error) {
//	var respStruct models.DiviLottery
//
//	resp, err := http.Get("https://statbot.neist.io/api/v1/statbot")
//	if err != nil {
//		return respStruct, err
//	}
//	defer resp.Body.Close()
//
//	body, err := ioutil.ReadAll(resp.Body)
//	if err != nil {
//		return respStruct, err
//	}
//	err = json.Unmarshal(body, &respStruct)
//	if err != nil {
//		return respStruct, err
//	}
//
//	return respStruct, errors.New("unable to LotteryInfo")
//}

func (d *Divi) MNSyncStatus(auth *models.CoinAuth) (models.DiviMNSyncStatus, error) {
	var respStruct models.DiviMNSyncStatus

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"mnsync\",\"params\":[\"status\"]}")
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

func (d Divi) NetworkDifficultyInfo() (float64, float64, error) {
	// https://chainz.cryptoid.info/ftc/api.dws?q=getdifficulty

	resp, err := http.Get("https://chainz.cryptoid.info/" + strings.ToLower(d.CoinNameAbbrev()) + "/api.dws?q=getdifficulty")
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

func (d Divi) NewAddress(auth *models.CoinAuth) (models.DiviGetNewAddress, error) {
	var respStruct models.DiviGetNewAddress

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

func (d Divi) RemoveCoreFiles(dir string) error {
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

func (d Divi) RPCDefaultUsername() string {
	return cRPCUser
}

func (d Divi) RPCDefaultPort() string {
	return cRPCPort
}

func (d Divi) StakingStatus(auth *models.CoinAuth) (models.DiviStakingStatus, error) {
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

func (d Divi) SendToAddress(coinAuth *models.CoinAuth, address string, amount float32) (returnResp models.GenericResponse, err error) {
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

func (d Divi) StartDaemon(displayOutput bool, appFolder string) error {
	b, _ := d.DaemonRunning()
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

func (d Divi) StopDaemon(auth *models.CoinAuth) error {
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

func (d Divi) TipAddress() string {
	return cTipAddress
}

func (d Divi) ValidateAddress(ad string) bool {
	// First, work out what the coin type is
	// If the length of the address is not exactly 34 characters...
	if len(ad) != 34 {
		return false
	}
	sFirst := ad[0]

	// 68 = UTF for D
	if sFirst != 68 {
		return false
	}

	return true
}

func (d Divi) UnarchiveBlockchainSnapshot() error {
	coinDir, err := d.HomeDirFullPath()
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

func (d Divi) UpdateTickerInfo() (ticker models.DiviTicker, err error) {
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

func (d *Divi) unarchiveFile(fullFilePath, location string) error {
	if err := archiver.Unarchive(fullFilePath, location); err != nil {
		return fmt.Errorf("unable to unarchive file: %v - %v", fullFilePath, err)
	}
	switch runtime.GOOS {
	case "windows":
		defer os.RemoveAll(location + cDownloadFileWindows)
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			defer os.RemoveAll(location + cDownloadFileArm32)
		case "arm64":
			return errors.New("arm64 is not currently supported for :" + cCoinName)
		case "386":
			return errors.New("linux 386 is not currently supported for :" + cCoinName)
		case "amd64":
			defer os.RemoveAll(location + cDownloadFileLinux)
		}
	}

	defer os.Remove(fullFilePath)

	return nil
}

func (d Divi) WalletAddress(auth *models.CoinAuth) (string, error) {
	var sAddress string
	addresses, _ := d.ListReceivedByAddress(auth, true)
	if len(addresses.Result) > 0 {
		sAddress = addresses.Result[0].Address
	} else {
		r, err := d.NewAddress(auth)
		if err != nil {
			return "", err
		}
		sAddress = r.Result
	}

	return sAddress, nil
}

func (d Divi) WalletBackup(coinAuth *models.CoinAuth, destDir string) (models.GenericResponse, error) {
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

func (d Divi) WalletEncrypt(coinAuth *models.CoinAuth, pw string) (models.GenericResponse, error) {
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

func (d Divi) WalletInfo(auth *models.CoinAuth) (models.DiviWalletInfo, error) {
	var respStruct models.DiviWalletInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetWalletInfo + "\",\"params\":[]}")
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

func (d Divi) WalletLoadingStatus(auth *models.CoinAuth) models.WLSType {
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

func (d Divi) WalletNeedsEncrypting(coinAuth *models.CoinAuth) (bool, error) {
	wi, err := d.WalletInfo(coinAuth)
	if err != nil {
		return true, errors.New("Unable to perform WalletInfo " + err.Error())
	}

	if wi.Result.EncryptionStatus == CWalletESUnencrypted {
		return true, nil
	}

	return false, nil
}

func (d Divi) WalletResync(appFolder string) error {
	daemonRunning, err := d.DaemonRunning()
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

func (d Divi) WalletSecurityState(coinAuth *models.CoinAuth) (models.WEType, error) {
	wi, err := d.WalletInfo(coinAuth)
	if err != nil {
		return models.WETUnknown, errors.New("Unable to GetWalletSecurityState: " + err.Error())
	}

	if wi.Result.EncryptionStatus == CWalletESLocked {
		return models.WETLocked, nil
	} else if wi.Result.EncryptionStatus == CWalletESUnlocked {
		return models.WETUnlocked, nil
	} else if wi.Result.EncryptionStatus == CWalletESUnlockedForStaking {
		return models.WETUnlockedForStaking, nil
	} else if wi.Result.EncryptionStatus == CWalletESUnencrypted {
		return models.WETUnencrypted, nil
	} else {
		return models.WETUnknown, nil
	}
}

func (d Divi) WalletUnlock(coinAuth *models.CoinAuth, pw string) error {
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

func (d Divi) WalletUnlockFS(coinAuth *models.CoinAuth, pw string) error {
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

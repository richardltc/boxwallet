package bend

import (
	"bufio"
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

	"github.com/mholt/archiver"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/rjminternet"
)

const (
	cCoinName       string = "PIVX"
	cCoinNameAbbrev string = "PIVX"

	//cCoreVersion           string = "5.4.0"
	//cDownloadFileArm32            = "pivx-" + cCoreVersion + "-arm-linux-gnueabihf.tar.gz"
	//cDownloadFileArm64            = "pivx-" + cCoreVersion + "-aarch64-linux-gnu.tar.gz"
	//cDownloadFileLin              = "pivx-" + cCoreVersion + "-x86_64-linux-gnu.tar.gz"
	//cDownloadFileFilemacOS        = "pivx-" + cCoreVersion + "-osx64.tar.gz"
	//cDownloadFileWin              = "pivx-" + cCoreVersion + "-win64.zip"

	// Directory const.
	//cExtractedDirArm string = "pivx-" + cCoreVersion + "/"
	//cExtractedDirLin string = "pivx-" + cCoreVersion + "/"
	//cExtractedDirWin string = "pivx-" + cCoreVersion + "\\"
	cSaplingDirArm string = ".pivx-params" + "/"
	cSaplingDirLin string = ".pivx-params" + "/"
	cSaplingDirWin string = "PIVXParams" + "\\"

	cAPIURL string = "https://api.github.com/repos/PIVX-Project/PIVX/releases/latest"
	//cDownloadURL string = "https://github.com/PIVX-Project/PIVX/releases/download/v" + cCoreVersion + "/"

	// PIVX Wallet Constants
	cHomeDirLin string = ".pivx"
	cHomeDirWin string = "PIVX"

	// File constants.
	cConfFile      string = "pivx.conf"
	cCliFileLin    string = "pivx-cli"
	cCliFileWin    string = "pivx-cli.exe"
	cDaemonFileLin string = "pivxd"
	cDaemonFileWin string = "pivxd.exe"
	cTxFileLin     string = "pivx-tx"
	cTxFileWin     string = "pivx-tx.exe"

	cSapling1 string = "sapling-output.params"
	cSapling2 string = "sapling-spend.params"

	// Tips address
	cTipAddress string = "D69t8ja9KZNcxdEwWVVBFKD7YjLnMuaUYr"

	// pivx.conf file constants
	cRPCUser string = "pivxrpc"
	cRPCPort string = "51473"
)

type PIVX struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

func (p PIVX) Bootstrap(rpcUser, rpcPassword, ip, port string) {
	p.RPCUser = rpcUser
	p.RPCPassword = rpcPassword
	p.IPAddress = ip
	p.Port = port
}

func (p PIVX) AbbreviatedCoinName() string {
	return cCoinNameAbbrev
}

func (p PIVX) AllBinaryFilesExist(dir string) (bool, error) {
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
		if !fileutils.FileExists(dir + cTxFileLin) {
			return false, nil
		}
	}

	return true, nil
}

func (p PIVX) AnyAddresses(auth *models.CoinAuth) (bool, error) {
	addresses, err := p.ListReceivedByAddress(auth, false)
	if err != nil {
		return false, err
	}
	if len(addresses.Result) > 0 {
		return true, nil
	}

	return false, nil
}

func (p PIVX) BackupCoreFiles(dir string) error {
	if err := fileutils.BackupFile(dir, cDaemonFileLin, dir, "", true); err != nil {
		return err
	}
	if err := fileutils.BackupFile(dir, cCliFileLin, dir, "", true); err != nil {
		return err
	}
	if err := fileutils.BackupFile(dir, cTxFileLin, dir, "", true); err != nil {
		return err
	}

	return nil
}

// BlockchainDataExists - Returns true if the Blockchain data exists for the specified coin
func (p PIVX) BlockchainDataExists() (bool, error) {
	coinDir, err := p.HomeDirFullPath()
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

func (p PIVX) BlockchainInfo(auth *models.CoinAuth) (models.PIVXBlockchainInfo, error) {
	var respStruct models.PIVXBlockchainInfo

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

func (p PIVX) BlockchainIsSynced(coinAuth *models.CoinAuth) (bool, error) {
	bci, err := p.BlockchainInfo(coinAuth)
	if err != nil {
		return false, err
	}

	if bci.Result.Verificationprogress > 0.99999 {
		return true, nil
	}

	return false, nil
}

func (p PIVX) ConfFile() string {
	return cConfFile
}

func (p PIVX) CoinName() string {
	return cCoinName
}

func (p PIVX) CoinNameAbbrev() string {
	return cCoinNameAbbrev
}

func (p PIVX) DaemonFilename() string {
	if runtime.GOOS == "windows" {
		return cDaemonFileWin
	}

	return cDaemonFileLin
}

func (p PIVX) DaemonRunning() (bool, error) {
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
	}

	return false, err
}

// DownloadCoin - Downloads the PIVX files into the specified location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (p PIVX) DownloadCoin(location string) error {
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

	//switch runtime.GOOS {
	//case "windows":
	//	fullFilePath = location + cDownloadFileWin
	//	fullFileDLURL = cDownloadURL + cDownloadFileWin
	//case "linux":
	//	switch runtime.GOARCH {
	//	case "arm":
	//		fullFilePath = location + cDownloadFileArm32
	//		fullFileDLURL = cDownloadURL + cDownloadFileArm32
	//	case "arm64":
	//		fullFilePath = location + cDownloadFileArm64
	//		fullFileDLURL = cDownloadURL + cDownloadFileArm64
	//	case "386":
	//		return errors.New("linux 386 is not currently supported for :" + cCoinName)
	//	case "amd64":
	//		fullFilePath = location + cDownloadFileLin
	//		fullFileDLURL = cDownloadURL + cDownloadFileLin
	//	}
	//}

	if err := rjminternet.DownloadFile(fullFilePath, fullFileDLURL); err != nil {
		return fmt.Errorf("unable to download file: %v - %v", fullFilePath+fullFileDLURL, err)
	}

	// Unarchive the files
	if err := p.unarchiveFile(fullFilePath, location, downloadFile); err != nil {
		return err
	}

	return nil
}

func (p PIVX) extractedDir() (string, error) {
	ghInfo, err := latestAssets()
	if err != nil {
		return "", err
	}

	var s string
	switch runtime.GOOS {
	case "windows":
		tn := strings.ReplaceAll(ghInfo.TagName, "v", "")
		s = strings.ToLower(cCoinName) + "-" + tn + "\\"
	case "linux":
		tn := strings.ReplaceAll(ghInfo.TagName, "v", "")
		s = strings.ToLower(cCoinName) + "-" + tn + "/"
	default:
		return "", errors.New("unable to determine runtime.GOOS")
	}

	return s, nil
}

func (p PIVX) HomeDir() string {
	if runtime.GOOS == "windows" {
		return cHomeDirWin
	} else {
		return cHomeDirLin
	}
}

func (p PIVX) HomeDirFullPath() (string, error) {
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

func (p PIVX) Info(auth *models.CoinAuth) (models.PIVXGetInfo, string, error) {
	var respStruct models.PIVXGetInfo

	for i := 1; i < 300; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetInfo + "\",\"params\":[]}")
		req, err := http.NewRequest("POST", "http://"+auth.IPAddress+":"+auth.Port, body)
		if err != nil {
			return respStruct, "", err
		}
		req.SetBasicAuth(auth.RPCUser, auth.RPCPassword)
		req.Header.Set("Content-Type", "text/plain;")

		for j := 1; j < 50; j++ {
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				time.Sleep(1 * time.Second)
				continue
			}
			defer resp.Body.Close()
			bodyResp, err := ioutil.ReadAll(resp.Body)
			if err != nil {
				return respStruct, "", err
			}

			// Check to make sure we are not loading the wallet
			if bytes.Contains(bodyResp, []byte("Loading")) ||
				bytes.Contains(bodyResp, []byte("Rescanning")) ||
				bytes.Contains(bodyResp, []byte("Rewinding")) ||
				bytes.Contains(bodyResp, []byte("RPC in warm-up")) ||
				bytes.Contains(bodyResp, []byte("Verifying")) {
				// The wallet is still loading, so print message, and sleep for 3 seconds and try again.
				var errStruct models.GenericResponse
				err = json.Unmarshal(bodyResp, &errStruct)
				if err != nil {
					return respStruct, "", err
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

// Install - Puts the freshly downloaded files into their correct location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (p PIVX) Install(location string) error {

	// Copy files to correct location
	var srcPath, srcFileCLI, srcFileDaemon, srcFileTX, dirToRemove string

	extractedDir, _ := p.extractedDir()
	switch runtime.GOOS {
	case "windows":
		srcPath = location + extractedDir
		srcFileCLI = cCliFileWin
		srcFileDaemon = cDaemonFileWin
		srcFileTX = cTxFileWin
	case "linux":
		switch runtime.GOARCH {
		case "arm", "arm64":
			srcPath = location + extractedDir + "bin/"
			srcFileCLI = cCliFileLin
			srcFileDaemon = cDaemonFileLin
			srcFileTX = cTxFileLin
			dirToRemove = location + extractedDir
		case "amd64":
			srcPath = location + extractedDir + "bin/"
			srcFileCLI = cCliFileLin
			srcFileDaemon = cDaemonFileLin
			srcFileTX = cTxFileLin
			dirToRemove = location + extractedDir
		default:
			return errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
		}
	default:
		return errors.New("unable to determine runtime.GOOS")
	}

	// If the coin-cli file doesn't exist the copy it.
	if _, err := os.Stat(location + srcFileCLI); os.IsNotExist(err) {
		if err := fileutils.FileCopy(srcPath+srcFileCLI, location+srcFileCLI, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+srcFileCLI, location+srcFileCLI, err)
		}
	}
	if err := os.Chmod(location+srcFileCLI, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+srcFileCLI, err)
	}

	// If the coind file doesn't exist the copy it.
	if _, err := os.Stat(location + srcFileDaemon); os.IsNotExist(err) {
		if err := fileutils.FileCopy(srcPath+srcFileDaemon, location+srcFileDaemon, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+srcFileDaemon, location+srcFileDaemon, err)
		}
	}
	if err := os.Chmod(location+srcFileDaemon, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+srcFileDaemon, err)
	}

	// If the cointx file doesn't exist the copy it.
	if _, err := os.Stat(location + srcFileTX); os.IsNotExist(err) {
		if err := fileutils.FileCopy(srcPath+srcFileTX, location+srcFileTX, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+srcFileTX, location+srcFileTX, err)
		}
	}
	if err := os.Chmod(location+srcFileTX, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+srcFileTX, err)
	}

	srcSapDir := location + extractedDir + "share/pivx/"
	dstSapDir, err := p.SaplingDir()
	if err != nil {
		return errors.New("unable to get SaplingDir: " + err.Error())
	}
	// Make sure the Sapling directory exists
	if err := os.MkdirAll(dstSapDir, os.ModePerm); err != nil {
		return errors.New("unable to make SaplingDir: " + err.Error())
	}
	// Sapling1
	if !fileutils.FileExists(dstSapDir + cSapling1) {
		if err := fileutils.FileCopy(srcSapDir+cSapling1, dstSapDir+cSapling1, false); err != nil {
			return errors.New("unable to copyFile from: " + location + cSapling1 + " to: " + dstSapDir + cSapling1 + ": " + err.Error())
		}
	}
	if err := os.Chmod(dstSapDir+cSapling1, 0777); err != nil {
		return errors.New("unable to chmod file: " + dstSapDir + cSapling1 + " - " + err.Error())
	}

	// Sapling2
	if !fileutils.FileExists(dstSapDir + cSapling2) {
		if err := fileutils.FileCopy(srcSapDir+cSapling2, dstSapDir+cSapling2, false); err != nil {
			return errors.New("unable to copyFile from: " + location + cSapling2 + " to: " + dstSapDir + cSapling2 + ": " + err.Error())
		}
	}
	if err := os.Chmod(dstSapDir+cSapling1, 0777); err != nil {
		return errors.New("unable to chmod file: " + dstSapDir + cSapling2 + " - " + err.Error())
	}

	if err := os.RemoveAll(dirToRemove); err != nil {
		return err
	}

	return nil
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

func (p *PIVX) MNSyncStatus(auth *models.CoinAuth) (models.PIVXMNSyncStatus, error) {
	var respStruct models.PIVXMNSyncStatus

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

func (p PIVX) NetworkDifficultyInfo() (float64, float64, error) {
	// https://chainz.cryptoid.info/ftc/api.dws?q=getdifficulty

	resp, err := http.Get("https://chainz.cryptoid.info/" + strings.ToLower(p.CoinNameAbbrev()) + "/api.dws?q=getdifficulty")
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

func (p PIVX) NewAddress(auth *models.CoinAuth) (models.PIVXGetNewAddress, error) {
	var respStruct models.PIVXGetNewAddress

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

func (p PIVX) RemoveCoreFiles(dir string) error {
	srcFolder := fileutils.AddTrailingSlash(dir)

	if err := os.RemoveAll(srcFolder + cDaemonFileLin); err != nil {
		return err
	}
	if err := os.RemoveAll(srcFolder + cCliFileLin); err != nil {
		return err
	}
	if err := os.RemoveAll(srcFolder + cTxFileLin); err != nil {
		return err
	}

	return nil
}

func (p PIVX) RPCDefaultUsername() string {
	return cRPCUser
}

func (p PIVX) RPCDefaultPort() string {
	return cRPCPort
}

func (p *PIVX) StakingStatus() (models.PIVXStakingStatus, error) {
	var respStruct models.PIVXStakingStatus

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getstakingstatus\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+p.IPAddress+":"+p.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(p.RPCUser, p.RPCPassword)
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

func (p PIVX) TipAddress() string {
	return cTipAddress
}

func (p PIVX) ListReceivedByAddress(coinAuth *models.CoinAuth, includeZero bool) (models.PIVXListReceivedByAddress, error) {
	var respStruct models.PIVXListReceivedByAddress

	var s string
	if includeZero {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"listreceivedbyaddress\",\"params\":[1, true]}"
	} else {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"listreceivedbyaddress\",\"params\":[1, false]}"
	}
	body := strings.NewReader(s)
	req, err := http.NewRequest("POST", "http://"+p.IPAddress+":"+p.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(p.RPCUser, p.RPCPassword)
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

func (p *PIVX) ListTransactions() (models.PIVXListTransactions, error) {
	var respStruct models.PIVXListTransactions

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandListTransactions + "\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+p.IPAddress+":"+p.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(p.RPCUser, p.RPCPassword)
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

func (p PIVX) SaplingDir() (string, error) {
	var s string
	u, err := user.Current()
	if err != nil {
		return "", err
	}
	hd := u.HomeDir
	if runtime.GOOS == "windows" {
		// add the "appdata\roaming" part.
		s = fileutils.AddTrailingSlash(hd) + "appdata\\roaming\\" + fileutils.AddTrailingSlash(cSaplingDirWin)
	} else {
		s = fileutils.AddTrailingSlash(hd) + fileutils.AddTrailingSlash(cSaplingDirLin)
	}

	return s, nil
}

func (p PIVX) SendToAddress(coinAuth *models.CoinAuth, address string, amount float32) (returnResp models.GenericResponse, err error) {
	var respStruct models.GenericResponse

	sAmount := fmt.Sprintf("%v", amount)

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

func (p PIVX) StartDaemon(displayOutput bool, appFolder string) error {
	b, _ := p.DaemonRunning()
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
			fmt.Println("Attempting to run the pivxd daemon...")
		}

		cmdRun := exec.Command(appFolder + cDaemonFileLin)
		stdout, err := cmdRun.StdoutPipe()
		if err != nil {
			return err
		}
		err = cmdRun.Start()
		if err != nil {
			return err
		}

		buf := bufio.NewReader(stdout)
		num := 1
		for {
			line, _, _ := buf.ReadLine()
			if num > 3 {
				os.Exit(0)
			}
			num++
			if string(line) == "PIVX server starting" {
				if displayOutput {
					fmt.Println("PIVX server starting")
				}
				return nil
			} else {
				return errors.New("unable to start PIVX server: " + string(line))
			}
		}
	}

	return nil
}

func (p PIVX) StopDaemon(auth *models.CoinAuth) error {
	var respStruct models.GenericResponse

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

func (p *PIVX) UnlockWallet(pw string) error {
	var respStruct models.GenericResponse

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",0]}")
	req, err := http.NewRequest("POST", "http://"+p.IPAddress+":"+p.Port, body)
	if err != nil {
		return err
	}
	req.SetBasicAuth(p.RPCUser, p.RPCPassword)
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

func (p PIVX) UpdateTickerInfo() (ticker models.PIVXTicker, err error) {
	resp, err := http.Get("https://ticker.neist.io/PIVX")
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

func (p PIVX) ValidateAddress(ad string) bool {
	// First, work out what the coin type is
	// If the length of the address is not exactly 34 characters...
	if len(ad) != 34 {
		return false
	}
	sFirst := ad[0]

	// 44 = UTF for D
	if sFirst != 44 {
		return false
	}

	return true
}

func (p PIVX) WalletAddress(auth *models.CoinAuth) (string, error) {
	var sAddress string
	addresses, _ := p.ListReceivedByAddress(auth, true)
	if len(addresses.Result) > 0 {
		sAddress = addresses.Result[0].Address
	} else {
		r, err := p.NewAddress(auth)
		if err != nil {
			return "", err
		}
		sAddress = r.Result
	}

	return sAddress, nil
}

func (p PIVX) WalletBackup(coinAuth *models.CoinAuth, destDir string) (models.GenericResponse, error) {
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

func (p PIVX) WalletEncrypt(coinAuth *models.CoinAuth, pw string) (models.GenericResponse, error) {
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
func (p PIVX) WalletInfo(auth *models.CoinAuth) (models.PIVXWalletInfo, error) {
	var respStruct models.PIVXWalletInfo

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

func (p PIVX) WalletLoadingStatus(auth *models.CoinAuth) models.WLSType {
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
		if bytes.Contains(bodyResp, []byte("RPC in warm-up")) {
			return models.WLSTRPCInWarmUp
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

func (p PIVX) WalletNeedsEncrypting(coinAuth *models.CoinAuth) (bool, error) {
	wi, err := p.WalletInfo(coinAuth)
	if err != nil {
		return true, errors.New("Unable to perform WalletInfo " + err.Error())
	}

	if wi.Result.UnlockedUntil == -1 {
		return true, nil
	}

	return false, nil
}

func (p PIVX) WalletResync(appFolder string) error {
	daemonRunning, err := p.DaemonRunning()
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

func (p PIVX) WalletSecurityState(coinAuth *models.CoinAuth) (models.WEType, error) {
	wi, err := p.WalletInfo(coinAuth)
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

func (p PIVX) WalletUnlock(coinAuth *models.CoinAuth, pw string) error {
	var respStruct models.PPCWalletUnlock

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",300]}")
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

func (p PIVX) WalletUnlockFS(coinAuth *models.CoinAuth, pw string) error {
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

//func fileExists(filename string) bool {
//	info, err := os.Stat(filename)
//	if os.IsNotExist(err) {
//		return false
//	}
//	return !info.IsDir()
//}

func (p *PIVX) unarchiveFile(fullFilePath, location, downloadFile string) error {
	if err := archiver.Unarchive(fullFilePath, location); err != nil {
		return fmt.Errorf("unable to unarchive file: %v - %v", fullFilePath, err)
	}
	//switch runtime.GOOS {
	//case "windows":
	//	defer os.RemoveAll(location + cDownloadFileWin)
	//case "linux":
	//	switch runtime.GOARCH {
	//	case "arm":
	//		defer os.RemoveAll(location + cDownloadFileArm32)
	//	case "arm64":
	//		defer os.RemoveAll(location + cDownloadFileArm64)
	//	case "386":
	//		return errors.New("linux 386 is not currently supported for :" + cCoinName)
	//	case "amd64":
	//		defer os.RemoveAll(location + cDownloadFileLin)
	//	}
	//}

	defer os.RemoveAll(location + downloadFile)

	defer os.RemoveAll(fullFilePath)

	return nil
}

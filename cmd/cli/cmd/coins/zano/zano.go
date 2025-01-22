package divi

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/shirou/gopsutil/v3/process"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/fileutils"
	"runtime"
	"strings"
	"syscall"
	"time"

	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/rjminternet"
)

const (
	cCoinName       string = "ZANO"
	cCoinNameAbbrev string = "ZANO"

	cHomeDir    string = ".Zano"
	cHomeDirWin string = "ZANO"

	cCoreVersion string = "2.0.1.367"
	// cDownloadFileArm32          = "zano-linux-x64-develop-v2.0.1.367%5Bd63feec%5D.AppImage"
	// cDownloadFileArm64          = "zano-linux-x64-develop-v2.0.1.367%5Bd63feec%5D.AppImage"
	cDownloadFileLinux   = "zano-linux-x64-develop-v2.0.1.367%5Bd63feec%5D.AppImage"
	cDownloadFileWindows = "zano-win-x64-release-v2.0.1.367[fe67a29].zip"

	cExtractedDirLinux = "squashfs-root"

	cDownloadURL = "https://build.zano.org/builds/"
	//cDownloadURLBS string = "https://snapshot/"

	cConfFile      string = "zano.conf"
	cCliFileLin    string = "simplewallet"
	cCliFileWin    string = "simplewallet.exe"
	cDaemonFileLin string = "zanod"
	cDaemonFileWin string = "zanod.exe"

	// zano.conf file constants
	cRPCUser string = "zanorpc"
	cRPCPort string = "11211"

	cTipAddress string = "ZxDHvWyQwKqi8ApBPhn3r9AnkRzBarAPCZvDkGQRnyPjjZs8WHL4PyfXyMipiJPTh6L8PHCp9LqNmMLp9NakETqL2gfpn92WP"

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

type Zano struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

func (z Zano) Bootstrap(rpcUser, rpcPassword, ip, port string) {
	z.RPCUser = rpcUser
	z.RPCPassword = rpcPassword
	z.IPAddress = ip
	if port == "" {
		z.Port = cRPCPort
	} else {
		z.Port = port
	}
}

func (z Zano) AbbreviatedCoinName() string {
	return cCoinNameAbbrev
}

func (z Zano) AllBinaryFilesExist(dir string) (bool, error) {
	if runtime.GOOS == "windows" {
		if !fileutils.FileExists(dir + cCliFileWin) {
			return false, nil
		}
		if !fileutils.FileExists(dir + cDaemonFileWin) {
			return false, nil
		}
	} else {
		if !fileutils.FileExists(dir + cCliFileLin) {
			return false, nil
		}
		if !fileutils.FileExists(dir + cDaemonFileLin) {
			return false, nil
		}
	}

	return true, nil
}

// BlockchainDataExists - Returns true if the Blockchain data exists for the specified coin
func (z Zano) BlockchainDataExists() (bool, error) {
	coinDir, err := z.HomeDirFullPath()
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

func (z Zano) BlockchainInfo(auth *models.CoinAuth) (models.NEXABlockchainInfo, error) {
	var respStruct models.NEXABlockchainInfo

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
	bodyResp, err := io.ReadAll(resp.Body)
	if err != nil {
		return respStruct, err
	}
	err = json.Unmarshal(bodyResp, &respStruct)
	if err != nil {
		return respStruct, err
	}

	return respStruct, nil
}

func (z Zano) BlockchainIsSynced(coinAuth *models.CoinAuth) (bool, error) {
	bci, err := z.BlockchainInfo(coinAuth)
	if err != nil {
		return false, err
	}

	if bci.Result.Verificationprogress > 0.99999 {
		return true, nil
	}

	return false, nil
}

func (z Zano) ConfFile() string {
	return cConfFile
}

func (z Zano) CoinName() string {
	return cCoinName
}

func (z Zano) CoinNameAbbrev() string {
	return cCoinNameAbbrev
}

func (z Zano) DaemonFilename() string {
	if runtime.GOOS == "windows" {
		return cDaemonFileWin
	}

	return cDaemonFileLin
}

func (z Zano) DaemonRunning() (bool, error) {
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

// DownloadCoin - Downloads the Zano files into the specified location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (z Zano) DownloadCoin(location string) error {
	var fullFilePath, fullFileDLURL string

	switch runtime.GOOS {
	case "windows":
		fullFilePath = location + cDownloadFileWindows
		fullFileDLURL = cDownloadURL + cDownloadFileWindows
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			return errors.New("arm32 is not currently supported for :" + cCoinName)
		case "arm64":
			return errors.New("arm64 is not currently supported for :" + cCoinName)
		case "386":
			return errors.New("linux 386 is not currently supported for :" + cCoinName)
		case "amd64":
			fullFilePath = location + cDownloadFileLinux
			fullFileDLURL = cDownloadURL + cDownloadFileLinux
		}
	}

	_, err := os.Stat(fullFilePath)
	if os.IsNotExist(err) {
		if err := rjminternet.DownloadFile(fullFilePath, fullFileDLURL); err != nil {
			return fmt.Errorf("unable to download file: %v - %v", fullFilePath+fullFileDLURL, err)
		}
	}

	// Unarchive the files.
	// Actually, it's run AppImage --export on the file
	if err := z.unarchiveFile(fullFilePath, location); err != nil {
		return err
	}

	return nil
}

func (z Zano) HomeDir() string {
	if runtime.GOOS == "windows" {
		return cHomeDirWin
	} else {
		return cHomeDir
	}
}

func (z Zano) HomeDirFullPath() (string, error) {
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

func (z Zano) Info(auth *models.CoinAuth) (models.DiviGetInfo, string, error) {
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
		bodyResp, err := io.ReadAll(resp.Body)
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
func (z Zano) Install(location string) error {

	// Copy files to correct location
	var srcPath, sfCLI, sfD, sfTX, dirToRemove string

	switch runtime.GOOS {
	case "windows":
		srcPath = location + cDownloadFileWindows
		sfCLI = cCliFileWin
		sfD = cDaemonFileWin
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			srcPath = location + cExtractedDirLinux + "/usr/bin/"
			sfCLI = cCliFileLin
			sfD = cDaemonFileLin
			dirToRemove = location + cExtractedDirLinux
		case "arm64":
			srcPath = location + cExtractedDirLinux + "/usr/bin/"
			sfCLI = cCliFileLin
			sfD = cDaemonFileLin
			dirToRemove = location + cExtractedDirLinux
		case "amd64":
			srcPath = location + cExtractedDirLinux + "/usr/bin/"
			sfCLI = cCliFileLin
			sfD = cDaemonFileLin
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

	// If the cointx file doesn't already exist the copy it.
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

func (z Zano) RPCDefaultUsername() string {
	return cRPCUser
}

func (z Zano) RPCDefaultPort() string {
	return cRPCPort
}

func (z Zano) StartDaemon(displayOutput bool, appFolder string) error {
	b, _ := z.DaemonRunning()
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

		cmdRun := exec.Command(appFolder+cDaemonFileLin, "--no-console", "--no-predownload")

		// Redirect output to log files for debugging
		//outFile, err := os.Create("/home/richard/projects/richardmace.co.uk/boxwallet/daemon_stdout.log")
		//if err != nil {
		//	return fmt.Errorf("failed to create stdout log file: %v", err)
		//}
		//defer outFile.Close()

		cmdRun.Stdout = nil
		cmdRun.Stderr = nil
		// Set up process to run independently
		cmdRun.SysProcAttr = &syscall.SysProcAttr{
			Setpgid: true,
		}
		if err := cmdRun.Start(); err != nil {
			return err
		}

		if displayOutput {
			fmt.Println(cCoinName + " server starting")
		}
	}

	return nil
}

func (z Zano) StopDaemon(auth *models.CoinAuth) error {
	processes, err := process.Processes()
	if err != nil {
		return err
	}
	for _, p := range processes {
		n, err := p.Name()
		if err != nil {
			return err
		}
		if n == cDaemonFileLin {
			//log.Printf("killing %s", n)
			_ = p.SendSignal(syscall.SIGINT)
		}
	}

	return nil
}

func (z Zano) TipAddress() string {
	return cTipAddress
}

func (z Zano) unarchiveFile(fullFilePath, location string) error {
	// Make sure the file permissions are correctly set
	if err := os.Chmod(fullFilePath, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", fullFilePath, err)
	}

	cmd := exec.Command(fullFilePath, "--appimage-extract")
	cmd.Dir = location
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("command execution failed: %w\nOutput: %s", err, out)
	}

	switch runtime.GOOS {
	case "windows":
		defer os.RemoveAll(location + cDownloadFileWindows)
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			errors.New("arm32 is not currently supported for :" + cCoinName)
		case "arm64":
			errors.New("arm64 is not currently supported for :" + cCoinName)
		case "386":
			return errors.New("linux 386 is not currently supported for :" + cCoinName)
		case "amd64":
			defer os.RemoveAll(location + cDownloadFileLinux)
		}
	}

	defer os.RemoveAll(fullFilePath)

	return nil
}

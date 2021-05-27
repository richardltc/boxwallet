package coins

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"io/ioutil"
	"os"
	"runtime"
	"strings"
	"time"

	"github.com/AlecAivazis/survey/v2"
	"github.com/mitchellh/go-ps"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/rand"
)

const (
	CCoinNameDivi        string = "Divi"
	CCoinNameBitcoinPlus string = "BitcoinPlus"
	CCoinNameDenarius    string = "Denarius"
	CCoinNameDeVault     string = "DeVault"
	CCoinNameDigiByte    string = "DigiByte"
	CCoinNameFeathercoin string = "Feathercoin"
	CCoinNameGroestlcoin string = "Groestlcoin"
	CCoinNamePeercoin    string = "Peercoin"
	CCoinNamePhore       string = "Phore"
	CCoinNamePIVX        string = "PIVX"
	CCoinNameRapids      string = "Rapids"
	CCoinNameReddCoin    string = "ReddCoin"
	CCoinNameScala       string = "Scala"
	CCoinNameSyscoin     string = "Syscoin"
	CCoinNameTrezarcoin  string = "Trezarcoin"
	CCoinNameVertcoin    string = "Vertcoin"
)

type Coin interface {
	AllBinaryFilesExist(location string) (allExist bool, err error)
	BootStrap(rpcUser, rpcPassword, ip, port string)
	ConfFile() string
	DownloadCoin(location string) error
	HomeDirFullPath() (string, error)
	TipAddress() string
	Install(location string) error
}

type CoinBlockchain interface {
	BlockchainDataExists() (bool, error)
	CoinName() string
	DownloadBlockchain() error
	UnarchiveBlockchainSnapshot() error
}

type CoinDaemon interface {
	Filename() string
	Running() (bool, error)
	Start(displayOutput bool) error
	Stop() error
}

type CoinName interface {
	CoinName() string
	CoinNameAbbrev() string
}

type CoinRPCDefaults interface {
	RPCDefaultUsername() string
	RPCDefaultPort() string
}

type AddNodes interface {
	AddNodesAlreadyExist() bool
}

func AddTrailingSlash(filePath string) string {
	var lastChar = filePath[len(filePath)-1:]
	switch runtime.GOOS {
	case "windows":
		if lastChar == "\\" {
			return filePath
		} else {
			return filePath + "\\"
		}
	case "linux":
		if lastChar == "/" {
			return filePath
		} else {
			return filePath + "/"
		}
	}

	return ""
}

func BackupFile(srcFolder, srcFile, dstFolder, prefixStr string, failOnNoSrc bool) error {
	dt := time.Now()
	dtStr := dt.Format("2006-01-02")

	if !FileExists(srcFolder + srcFile) {
		if failOnNoSrc {
			return errors.New(srcFolder + srcFile + " doesn't exist")
		} else {
			return nil
		}
	}

	originalFile, err := os.Open(srcFolder + srcFile)
	if err != nil {
		return err
	}
	defer originalFile.Close()

	if dstFolder == "" {
		dstFolder = srcFolder
	}

	var s string
	if prefixStr != "" {
		s = prefixStr + "-"
	}

	newFile, err := os.Create(dstFolder + s + dtStr + "-" + srcFile)
	if err != nil {
		return err
	}
	defer newFile.Close()

	_, err = io.Copy(newFile, originalFile)
	if err != nil {
		return err
	}

	err = newFile.Sync()
	if err != nil {
		return err
	}

	return nil
}

func FileCopy(srcFile, destFile string, dispOutput bool) error {
	// Open original file
	originalFile, err := os.Open(srcFile)
	if err != nil {
		return err
	}
	defer originalFile.Close()

	// Create new file
	newFile, err := os.Create(destFile)
	if err != nil {
		return err
	}
	defer newFile.Close()

	// Copy the bytes to destination from source
	bytesWritten, err := io.Copy(newFile, originalFile)
	if err != nil {
		return err
	}
	if dispOutput {
		fmt.Printf("Copied %d bytes.", bytesWritten)
	}

	// Commit the file contents
	// Flushes memory to disk
	err = newFile.Sync()
	if err != nil {
		return err
	}

	return nil
}

func FileExists(filename string) bool {
	info, err := os.Stat(filename)
	if os.IsNotExist(err) {
		return false
	}
	return !info.IsDir()
}

func FindProcess(key string) (int, string, error) {
	pname := ""
	pid := 0
	err := errors.New("not found")
	process, _ := ps.Processes()

	for i := range process {
		if process[i].Executable() == key {
			pid = process[i].Pid()
			pname = process[i].Executable()
			err = nil
			break
		}
	}
	return pid, pname, err
}

func GetPasswordToEncryptWallet() string {
	for i := 0; i <= 2; i++ {
		epw1 := ""
		prompt := &survey.Password{
			Message: "Please enter a password to encrypt your wallet",
		}
		_ = survey.AskOne(prompt, &epw1)

		epw2 := ""
		prompt2 := &survey.Password{
			Message: "Now please re-enter your password",
		}
		_ = survey.AskOne(prompt2, &epw2)
		if epw1 != epw2 {
			fmt.Print("\nThe passwords don't match, please try again...\n")
		} else {
			return epw1
		}
	}
	return ""
}

func GetWalletEncryptionPassword() string {
	pw := ""
	prompt := &survey.Password{
		Message: "Please enter your wallet password",
	}
	survey.AskOne(prompt, &pw)
	return pw
}

func GetWalletEncryptionResp() bool {
	ans := false
	prompt := &survey.Confirm{
		Message: `Your wallet is currently UNENCRYPTED!

It is *highly* recommended that you encrypt your wallet before proceeding any further.

Encrypt it now?:`,
	}
	survey.AskOne(prompt, &ans)
	return ans
}

func GetStrAfterStr(value string, a string) string {
	// Get substring after a string.
	pos := strings.LastIndex(value, a)
	if pos == -1 {
		return ""
	}
	adjustedPos := pos + len(a)
	if adjustedPos >= len(value) {
		return ""
	}
	return value[adjustedPos:]
}

// GetStringAfterStrFromFile - Returns the string after the passed string: e.g line in file is "greeting=hi", if the stringToFind was "greeting=" it would return "hi""
func GetStringAfterStrFromFile(stringToFind, file string) (string, error) {
	if !FileExists(file) {
		return "", nil
	}

	data, err := ioutil.ReadFile(file)
	if err != nil {
		return "", err
	}
	scanner := bufio.NewScanner(strings.NewReader(string(data)))
	for scanner.Scan() {
		s := scanner.Text()
		if strings.Contains(s, stringToFind) {
			t := GetStrAfterStr(s, "=") //strings.Replace(s,stringToFind,"", -1)
			return t, nil
		}
	}
	return "", nil

}

func PopulateConfFile(confFile, homeDir, rpcUserCoin, rpcPortCoin string) (rpcUser, rpcPassword string, err error) {
	// Add rpcuser info if required, or retrieve the existing one
	bFileHasBeenBU := false
	bNeedToWriteStr := true
	var rpcu, rpcpw string

	// Create the coins home folder if required...
	if err := os.MkdirAll(homeDir, os.ModePerm); err != nil {
		return "", "", errors.New("unable to make directory - " + err.Error())
	}

	if FileExists(homeDir + confFile) {
		bStrFound, err := StringExistsInFile(models.CRPCUser+"=", homeDir+confFile)
		if err != nil {
			return "", "", fmt.Errorf("unable to search for text in file - %v", err)
		}
		if !bStrFound {
			// String not found
			if !bFileHasBeenBU {
				bFileHasBeenBU = true
				if err := BackupFile(homeDir, confFile, "", "", false); err != nil {
					return "", "", fmt.Errorf("unable to backup file - %v", err)
				}
			}
		} else {
			bNeedToWriteStr = false
			rpcu, err = GetStringAfterStrFromFile(models.CRPCUser+"=", homeDir+confFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
		}
	} else {
		// Set this to true, because the file has just been freshly created and we don't want to back it up
		bFileHasBeenBU = true
	}
	if bNeedToWriteStr {
		rpcu = rpcUserCoin
		if err := WriteTextToFile(homeDir+confFile, models.CRPCUser+"="+rpcu); err != nil {
			return "", "", err
		}
	}

	// Add rpcpassword info if required, or retrieve the existing one
	bNeedToWriteStr = true
	if FileExists(homeDir + confFile) {
		bStrFound, err := StringExistsInFile(models.CRPCPassword+"=", homeDir+confFile)
		if err != nil {
			return "", "", fmt.Errorf("unable to search for text in file - %v", err)
		}
		if !bStrFound {
			// String not found
			if !bFileHasBeenBU {
				bFileHasBeenBU = true
				if err := BackupFile(homeDir, confFile, "", "", false); err != nil {
					return "", "", fmt.Errorf("unable to backup file - %v", err)
				}
			}
		} else {
			bNeedToWriteStr = false
			rpcpw, err = GetStringAfterStrFromFile(models.CRPCPassword+"=", homeDir+confFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
		}
	}
	if bNeedToWriteStr {
		rpcpw = rand.String(20)
		if err := WriteTextToFile(homeDir+confFile, models.CRPCPassword+"="+rpcpw); err != nil {
			return "", "", err
		}
		if err := WriteTextToFile(homeDir+confFile, ""); err != nil {
			return "", "", err
		}
	}

	// Add daemon=1 info if required
	bNeedToWriteStr = true
	if FileExists(homeDir + confFile) {
		bStrFound, err := StringExistsInFile("daemon=1", homeDir+confFile)
		if err != nil {
			return "", "", fmt.Errorf("unable to search for text in file - %v", err)
		}
		if !bStrFound {
			// String not found
			if !bFileHasBeenBU {
				bFileHasBeenBU = true
				if err := BackupFile(homeDir, confFile, "", "", false); err != nil {
					return "", "", fmt.Errorf("unable to backup file - %v", err)
				}
			}
		} else {
			bNeedToWriteStr = false
		}
	}
	if bNeedToWriteStr {
		if err := WriteTextToFile(homeDir+confFile, "daemon=1"); err != nil {
			return "", "", err
		}
		if err := WriteTextToFile(homeDir+confFile, ""); err != nil {
			return "", "", err
		}
	}

	// Add server=1 info if required
	bNeedToWriteStr = true
	if FileExists(homeDir + confFile) {
		bStrFound, err := StringExistsInFile("server=1", homeDir+confFile)
		if err != nil {
			return "", "", fmt.Errorf("unable to search for text in file - %v", err)
		}
		if !bStrFound {
			// String not found
			if !bFileHasBeenBU {
				bFileHasBeenBU = true
				if err := BackupFile(homeDir, confFile, "", "", false); err != nil {
					return "", "", fmt.Errorf("unable to backup file - %v", err)
				}
			}
		} else {
			bNeedToWriteStr = false
		}
	}
	if bNeedToWriteStr {
		if err := WriteTextToFile(homeDir+confFile, "server=1"); err != nil {
			return "", "", err
		}
	}

	// Add rpcallowip= info if required
	bNeedToWriteStr = true
	if FileExists(homeDir + confFile) {
		bStrFound, err := StringExistsInFile("rpcallowip=", homeDir+confFile)
		if err != nil {
			return "", "", fmt.Errorf("unable to search for text in file - %v", err)
		}
		if !bStrFound {
			// String not found
			if !bFileHasBeenBU {
				bFileHasBeenBU = true
				if err := BackupFile(homeDir, confFile, "", "", false); err != nil {
					return "", "", fmt.Errorf("unable to backup file - %v", err)
				}
			}
		} else {
			bNeedToWriteStr = false
		}
	}
	if bNeedToWriteStr {
		if err := WriteTextToFile(homeDir+confFile, "rpcallowip=192.168.1.0/255.255.255.0"); err != nil {
			return "", "", err
		}
	}

	// Add rpcport= info if required
	bNeedToWriteStr = true
	if FileExists(homeDir + confFile) {
		bStrFound, err := StringExistsInFile("rpcport=", homeDir+confFile)
		if err != nil {
			return "", "", fmt.Errorf("unable to search for text in file - %v", err)
		}
		if !bStrFound {
			// String not found
			if !bFileHasBeenBU {
				bFileHasBeenBU = true
				if err := BackupFile(homeDir, confFile, "", "", false); err != nil {
					return "", "", fmt.Errorf("unable to backup file - %v", err)
				}
			}
		} else {
			bNeedToWriteStr = false
		}
	}
	if bNeedToWriteStr {
		if err := WriteTextToFile(homeDir+confFile, "rpcport="+rpcPortCoin); err != nil {
			return "", "", err
		}
	}

	return rpcu, rpcpw, nil

}

func StringExistsInFile(str, file string) (bool, error) {
	if !FileExists(file) {
		return false, nil
	}

	data, err := ioutil.ReadFile(file)
	if err != nil {
		return false, errors.New(err.Error())
	}
	scanner := bufio.NewScanner(strings.NewReader(string(data)))
	for scanner.Scan() {
		s := scanner.Text()
		if strings.Contains(s, str) {
			return true, nil
		}
	}
	return false, nil
}

func WriteTextToFile(fileName, text string) error {
	// Open a new file for writing only
	file, err := os.OpenFile(
		fileName,
		os.O_WRONLY|os.O_APPEND|os.O_CREATE,
		0666,
	)
	if err != nil {
		return err
	}
	defer file.Close()

	byteSlice := []byte(text + "\n")
	_, err = file.Write(byteSlice)
	if err != nil {
		return err
	}

	return nil
}

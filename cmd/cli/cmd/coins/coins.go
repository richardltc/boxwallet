package coins

import (
	"errors"
	"fmt"
	"github.com/AlecAivazis/survey/v2"
	"github.com/mitchellh/go-ps"
	"os"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/fileutils"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/rand"
)

const (
	CCoinNameDivi        string = "Divi"
	CCoinNameBitcoinPlus string = "BitcoinPlus"
	CCoinNameDenarius    string = "Denarius"
	CCoinNameDeVault     string = "DeVault"
	CCoinNameDigiByte    string = "DigiByte"
	CCoinNameDogeCash    string = "DogeCash"
	CCoinNameFeathercoin string = "Feathercoin"
	CCoinNameGroestlcoin string = "Groestlcoin"
	CCoinNameLitecoin    string = "Litecoin"
	CCoinNameNavcoin     string = "Navcoin"
	CCoinNameSpiderByte  string = "SpiderByte"
	CCoinNamePeercoin    string = "Peercoin"
	CCoinNamePhore       string = "Phore"
	CCoinNamePIVX        string = "PIVX"
	CCoinNamePrimecoin   string = "Primecoin"
	CCoinNameRapids      string = "Rapids"
	CCoinNameReddCoin    string = "ReddCoin"
	CCoinNameScala       string = "Scala"
	CCoinNameSyscoin     string = "Syscoin"
	CCoinNameTrezarcoin  string = "Trezarcoin"
	CCoinNameVertcoin    string = "Vertcoin"
)

type BackupCoreFiles interface {
	BackupCoreFiles(dir string) error
}

type CoinBlockchainIsSynced interface {
	BlockchainIsSynced(coinAuth *models.CoinAuth) (bool, error)
}

type Coin interface {
	AllBinaryFilesExist(location string) (allExist bool, err error)
	Bootstrap(rpcUser, rpcPassword, ip, port string)
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

type CoinCLI interface {
	CLIFilename() string
}

type CoinDaemon interface {
	DaemonFilename() string
	DaemonRunning() (bool, error)
	StartDaemon(displayOutput bool, appFolder string) error
	StopDaemon(auth *models.CoinAuth) error
}

type CoinAnyAddresses interface {
	AnyAddresses(auth *models.CoinAuth) (bool, error)
}

type RemoveBlockchainData interface {
	RemoveBlockchainData() error
}

type RemoveCoreFiles interface {
	RemoveCoreFiles(dir string) error
}

type CoinIsPOS interface {
	IsPOS() bool
}

type CoinName interface {
	CoinName() string
	CoinNameAbbrev() string
}

type CoinPrice interface {
	RefreshPrice()
}

type CoinRPCDefaults interface {
	RPCDefaultUsername() string
	RPCDefaultPort() string
}

type AddNodes interface {
	AddNodesAlreadyExist() bool
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

func PopulateConfFile(confFile, homeDir, rpcUserCoin, rpcPortCoin string) (rpcUser, rpcPassword string, err error) {
	// Add rpcuser info if required, or retrieve the existing one
	bFileHasBeenBU := false
	bNeedToWriteStr := true
	var rpcu, rpcpw string

	// Create the coins home folder if required...
	if err := os.MkdirAll(homeDir, os.ModePerm); err != nil {
		return "", "", errors.New("unable to make directory - " + err.Error())
	}

	if fileutils.FileExists(homeDir + confFile) {
		bStrFound, err := fileutils.StringExistsInFile(models.CRPCUser+"=", homeDir+confFile)
		if err != nil {
			return "", "", fmt.Errorf("unable to search for text in file - %v", err)
		}
		if !bStrFound {
			// String not found
			if !bFileHasBeenBU {
				bFileHasBeenBU = true
				if err := fileutils.BackupFile(homeDir, confFile, "", "", false); err != nil {
					return "", "", fmt.Errorf("unable to backup file - %v", err)
				}
			}
		} else {
			bNeedToWriteStr = false
			rpcu, err = fileutils.GetStringAfterStrFromFile(models.CRPCUser+"=", homeDir+confFile)
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
		if err := fileutils.WriteTextToFile(homeDir+confFile, "\n"+models.CRPCUser+"="+rpcu); err != nil {
			return "", "", err
		}
	}

	// Add rpcpassword info if required, or retrieve the existing one
	bNeedToWriteStr = true
	if fileutils.FileExists(homeDir + confFile) {
		bStrFound, err := fileutils.StringExistsInFile(models.CRPCPassword+"=", homeDir+confFile)
		if err != nil {
			return "", "", fmt.Errorf("unable to search for text in file - %v", err)
		}
		if !bStrFound {
			// String not found
			if !bFileHasBeenBU {
				bFileHasBeenBU = true
				if err := fileutils.BackupFile(homeDir, confFile, "", "", false); err != nil {
					return "", "", fmt.Errorf("unable to backup file - %v", err)
				}
			}
		} else {
			bNeedToWriteStr = false
			rpcpw, err = fileutils.GetStringAfterStrFromFile(models.CRPCPassword+"=", homeDir+confFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
		}
	}
	if bNeedToWriteStr {
		rpcpw = rand.String(20)
		if err := fileutils.WriteTextToFile(homeDir+confFile, models.CRPCPassword+"="+rpcpw); err != nil {
			return "", "", err
		}
		if err := fileutils.WriteTextToFile(homeDir+confFile, ""); err != nil {
			return "", "", err
		}
	}

	// Add daemon=1 info if required
	bNeedToWriteStr = true
	if fileutils.FileExists(homeDir + confFile) {
		bStrFound, err := fileutils.StringExistsInFile("daemon=1", homeDir+confFile)
		if err != nil {
			return "", "", fmt.Errorf("unable to search for text in file - %v", err)
		}
		if !bStrFound {
			// String not found
			if !bFileHasBeenBU {
				bFileHasBeenBU = true
				if err := fileutils.BackupFile(homeDir, confFile, "", "", false); err != nil {
					return "", "", fmt.Errorf("unable to backup file - %v", err)
				}
			}
		} else {
			bNeedToWriteStr = false
		}
	}
	if bNeedToWriteStr {
		if err := fileutils.WriteTextToFile(homeDir+confFile, "daemon=1"); err != nil {
			return "", "", err
		}
		if err := fileutils.WriteTextToFile(homeDir+confFile, ""); err != nil {
			return "", "", err
		}
	}

	// Add server=1 info if required
	bNeedToWriteStr = true
	if fileutils.FileExists(homeDir + confFile) {
		bStrFound, err := fileutils.StringExistsInFile("server=1", homeDir+confFile)
		if err != nil {
			return "", "", fmt.Errorf("unable to search for text in file - %v", err)
		}
		if !bStrFound {
			// String not found
			if !bFileHasBeenBU {
				bFileHasBeenBU = true
				if err := fileutils.BackupFile(homeDir, confFile, "", "", false); err != nil {
					return "", "", fmt.Errorf("unable to backup file - %v", err)
				}
			}
		} else {
			bNeedToWriteStr = false
		}
	}
	if bNeedToWriteStr {
		if err := fileutils.WriteTextToFile(homeDir+confFile, "server=1"); err != nil {
			return "", "", err
		}
	}

	// Add rpcallowip= info if required
	bNeedToWriteStr = true
	if fileutils.FileExists(homeDir + confFile) {
		bStrFound, err := fileutils.StringExistsInFile("rpcallowip=", homeDir+confFile)
		if err != nil {
			return "", "", fmt.Errorf("unable to search for text in file - %v", err)
		}
		if !bStrFound {
			// String not found
			if !bFileHasBeenBU {
				bFileHasBeenBU = true
				if err := fileutils.BackupFile(homeDir, confFile, "", "", false); err != nil {
					return "", "", fmt.Errorf("unable to backup file - %v", err)
				}
			}
		} else {
			bNeedToWriteStr = false
		}
	}
	if bNeedToWriteStr {
		if err := fileutils.WriteTextToFile(homeDir+confFile, "rpcallowip=192.168.1.0/255.255.255.0"); err != nil {
			return "", "", err
		}
	}

	// Add rpcport= info if required.
	bNeedToWriteStr = true
	if fileutils.FileExists(homeDir + confFile) {
		bStrFound, err := fileutils.StringExistsInFile("rpcport=", homeDir+confFile)
		if err != nil {
			return "", "", fmt.Errorf("unable to search for text in file - %v", err)
		}
		if !bStrFound {
			// String not found
			if !bFileHasBeenBU {
				bFileHasBeenBU = true
				if err := fileutils.BackupFile(homeDir, confFile, "", "", false); err != nil {
					return "", "", fmt.Errorf("unable to backup file - %v", err)
				}
			}
		} else {
			bNeedToWriteStr = false
		}
	}
	if bNeedToWriteStr {
		if err := fileutils.WriteTextToFile(homeDir+confFile, "rpcport="+rpcPortCoin); err != nil {
			return "", "", err
		}
	}

	return rpcu, rpcpw, nil
}

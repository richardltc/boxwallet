package app

import (
	"errors"
	"os/user"
	"runtime"
)

const (
	cAppName        string = "BoxWallet"
	CUpdaterAppName string = "bwupdater"
	cAppVersion     string = "0.49.0"
	CAppFilename    string = "boxwallet"
	CAppFilenameWin string = "boxwallet.exe"
	CAppLogfile     string = "boxwallet.log"

	cAppWorkingDirLin string = ".boxwallet"
	cAppWorkingDirWin string = "BoxWallet"
	// CCommandEncryptWallet - Needed by dash command
	CCommandEncryptWallet  string = "encryptwallet"    // ./divi-cli encryptwallet “a_strong_password”
	cCommandRestoreWallet  string = "-hdseed="         // ./divid -debug-hdseed=the_seed -rescan (stop divid, rename wallet.dat, then run command)
	cCommandUnlockWallet   string = "walletpassphrase" // ./divi-cli walletpassphrase “password” 0
	cCommandUnlockWalletFS string = "walletpassphrase" // ./divi-cli walletpassphrase “password” 0 true
	cCommandLockWallet     string = "walletlock"       // ./divi-cli walletlock

	cUtfTick     string = "\u2713"
	CUtfTickBold string = "\u2714"

	cCircProg1 string = "\u25F7"
	cCircProg2 string = "\u25F6"
	cCircProg3 string = "\u25F5"
	cCircProg4 string = "\u25F4"

	cUtfLock string = "\u1F512"

	cProg1 string = "|"
	cProg2 string = "/"
	cProg3 string = "-"
	cProg4 string = "\\"
	cProg5 string = "|"
	cProg6 string = "/"
	cProg7 string = "-"
	cProg8 string = "\\"

	BUWWalletDat     string = "Backup wallet.dat"
	BUWDisplayHDSeed string = "Display recovery seed"
	BUWStoreSeed     string = "Store seed"
)

type App struct {
}

// FileName - Returns the name of the app binary file e.g. boxwallet or boxwallet.exe
func (a App) FileName() (string, error) {
	switch runtime.GOOS {
	case "arm":
		return CAppFilename, nil
	case "linux":
		return CAppFilename, nil
	case "windows":
		return CAppFilenameWin, nil
	default:
		err := errors.New("unable to determine runtime.GOOS")
		return "", err
	}
}

func (a App) HomeFolder() (string, error) {
	var s string
	u, err := user.Current()
	if err != nil {
		return "", err
	}
	hd := u.HomeDir
	if runtime.GOOS == "windows" {
		// add the "appdata\roaming" part.
		s = addTrailingSlash(hd) + "appdata\\roaming\\" + addTrailingSlash(cAppWorkingDirWin)
	} else {
		s = addTrailingSlash(hd) + addTrailingSlash(cAppWorkingDirLin)
	}
	return s, nil
}

func (a App) Name() string {
	return cAppName
}

func addTrailingSlash(filePath string) string {
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

func (a App) Version() string {
	return cAppVersion
}

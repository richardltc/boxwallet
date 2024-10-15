package app

import (
	"errors"
	"os/user"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/fileutils"
	"runtime"
)

const (
	cAppName        string = "BoxWallet"
	CUpdaterAppName string = "bwupdater"
	CAppVersion     string = "0.6.3"
	CAppFilename    string = "boxwallet"
	CAppFilenameWin string = "boxwallet.exe"

	cAppWorkingDirLin string = ".boxwallet"
	cAppWorkingDirWin string = "BoxWallet"
	//CCommandEncryptWallet - Needed by dash command.
	//CCommandEncryptWallet  string = "encryptwallet"    // ./divi-cli encryptwallet “a_strong_password”
	//cCommandRestoreWallet  string = "-hdseed="         // ./divid -debug-hdseed=the_seed -rescan (stop divid, rename wallet.dat, then run command)
	//cCommandUnlockWallet   string = "walletpassphrase" // ./divi-cli walletpassphrase “password” 0
	//cCommandUnlockWalletFS string = "walletpassphrase" // ./divi-cli walletpassphrase “password” 0 true
	//cCommandLockWallet     string = "walletlock"       // ./divi-cli walletlock

	BUWWalletDat     string = "Backup wallet.dat"
	BUWDisplayHDSeed string = "Display recovery seed"
	BUWStoreSeed     string = "Store seed"
)

type App struct {
}

// FileName - Returns the name of the app binary file e.g. boxwallet or boxwallet.exe (for Windows)
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
		// add the "appdata\roaming" part..
		s = fileutils.AddTrailingSlash(hd) + "appdata\\roaming\\" + fileutils.AddTrailingSlash(cAppWorkingDirWin)
	} else {
		s = fileutils.AddTrailingSlash(hd) + fileutils.AddTrailingSlash(cAppWorkingDirLin)
	}

	return s, nil
}

func (a App) Name() string {
	return cAppName
}

func (a App) UpdaterName() string {
	return CUpdaterAppName
}

func (a App) Version() string {
	return CAppVersion
}

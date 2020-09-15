package bend

const (
	CCoinNameTrezarcoin string = "Trezarcoin"

	CTrezarcoinCoreVersion string = "2.1.1"
	CDFTrezarcoinRPi       string = "Trezarcoin-" + CTrezarcoinCoreVersion + "-rPI.zip"
	CDFTrezarcoinLinux     string = "trezarcoin-" + CTrezarcoinCoreVersion + "-linux64.tar.gz"
	CDFTrezarcoinWindows   string = "trezarcoin-" + CTrezarcoinCoreVersion + "-win64-setup.exe"

	CDownloadURLTC string = "https://github.com/TrezarCoin/TrezarCoin/releases/download/" + CTrezarcoinCoreVersion + ".0/"

	// CTrezarcoinAppVersion - The app version of Trezarcoin
	CTrezarcoinHomeDir    string = ".trezarcoin"
	CTrezarcoinHomeDirWin string = "TREZARCOIN"

	CTrezarcoinConfFile   string = "trezarcoin.conf"
	CTrezarcoinCliFile    string = "trezarcoin-cli"
	CTrezarcoinCliFileWin string = "trezarcoin-cli.exe"
	CTrezarcoinDFile      string = "trezarcoind"
	CTrezarcoinDFileWin   string = "trezarcoind.exe"
	CTrezarcoinTxFile     string = "trezarcoin-tx"
	CTrezarcoinTxFileWin  string = "trezarcoin-tx.exe"

	// trezarcoin.conf file constants
	CTrezarcoinRPCPort string = "17299"
)

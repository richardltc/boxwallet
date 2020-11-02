package bend

const (
	CCoinNameGroestlcoin string = "Groestlcoin"

	CGroestlcoinCoreVersion string = "2.20.1"
	CDFGroestlcoinRPi       string = "groestlcoin-" + CGroestlcoinCoreVersion + "-arm-linux-gnueabihf.taf.gz"
	CDFGroestlcoinLinux     string = "groestlcoin-" + CGroestlcoinCoreVersion + "-x86_64-linux-gnu-tar.gz"
	CDFGroestlcoinWindows   string = "groestlcoin-" + CGroestlcoinCoreVersion + "-win64.zip"

	CGroestlcoinExtractedDirLinux = "groestlcoin-" + CGroestlcoinCoreVersion + "-linux-amd64/"

	CDownloadURLGroestlcoin string = "https://github.com/Groestlcoin/groestlcoin/releases/download/" + CGroestlcoinCoreVersion + "/"

	CGroestlcoinHomeDir    string = ".groestlcoin"
	CGroestlcoinHomeDirWin string = "GROESTLCOIN"

	CGroestlcoinConfFile   string = "groestlcoin.conf"
	CGroestlcoinCliFile    string = "groestlcoin-cli"
	CGroestlcoinCliFileWin string = "groestlcoin-cli.exe"
	CGroestlcoinDFile      string = "groestlcoind"
	CGroestlcoinDFileWin   string = "groestlcoind.exe"
	CGroestlcoinTxFile     string = "groestlcoin-tx"
	CGroestlcoinTxFileWin  string = "groestlcoin-tx.exe"

	CGroestlcoinRPCPort string = "1441"
)

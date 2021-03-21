package bend

const (
	CCoinNameSyscoin   string = "Syscoin"
	CCoinAbbrevSyscoin string = "SYS"

	CSyscoinCoreVersion   string = "4.2.0rc11"
	CDFSyscoinFileArm32          = "syscoin-" + CSyscoinCoreVersion + "-arm-linux-gnueabihf.tar.gz"
	CDFSyscoinFileArm64          = "syscoin-" + CSyscoinCoreVersion + "-aarch64-linux-gnu.tar.gz"
	CDFSyscoinFileLinux          = "syscoin-" + CSyscoinCoreVersion + "-x86_64-linux-gnu.tar.gz"
	CDFSyscoinFilemacOS          = "syscoin-" + CSyscoinCoreVersion + "-osx64.tar.gz"
	CDFSyscoinFileWindows        = "syscoin-" + CSyscoinCoreVersion + "-win64.zip"

	// Directory const.
	CSyscoinXExtractedDirArm    string = "syscoin-" + CSyscoinCoreVersion + "/"
	CSyscoinExtractedDirLinux   string = "syscoin-" + CSyscoinCoreVersion + "/"
	CSyscoinExtractedDirWindows string = "syscoin-" + CSyscoinCoreVersion + "\\"

	CDownloadURLSyscoin string = "https://github.com/syscoin/syscoin/releases/download/v" + CSyscoinCoreVersion + "/"

	// Syscoin Wallet Constants
	cSyscoinHomeDir    string = ".syscoin"
	cSyscoinHomeDirWin string = "syscoin"

	// File constants
	CSyscoinConfFile   string = "syscoin.conf"
	CSyscoinCliFile    string = "syscoin-cli"
	CSyscoinCliFileWin string = "syscoin-cli.exe"
	CSyscoinDFile      string = "syscoind"
	CSyscoinDFileWin   string = "syscoind.exe"
	CSyscoinTxFile     string = "syscoin-tx"
	CSyscoinTxFileWin  string = "syscoin-tx.exe"

	// pivx.conf file constants
	CSyscoinRPCUser string = "syscoinrpc"
	CSyscoinRPCPort string = "8370"
)

# Usage: scoop virustotal <app> [options]
# Summary: Look for app's hash on virustotal.com
# Help: Look for app's hash (MD5, SHA1 or SHA256) on virustotal.com
#
# The download's hash is also a key to access VirusTotal's scan results.
# This allows to check the safety of the files without even downloading
# them in many cases.  If the hash is unknown to VirusTotal, the
# download link is printed to submit it to VirusTotal.
#
# Exit codes:
# 0 -> success
# 1 -> problem parsing arguments
# 2 -> at least one package was marked unsafe by VirusTotal
# 4 -> at least one exception was raised while looking for info
# 8 -> at least one package couldn't be queried because its hash type
#      isn't supported by VirusTotal, the manifest couldn't be found
#      or didn't contain a hash
# Note: the exit codes (2, 4 & 8) may be combined, e.g. 6 -> exit codes
#       2 & 4 combined
#
# Options:
#   -a, --arch <32bit|64bit>  Use the specified architecture, if the app supports it
#   -s, --scan For packages where VirusTotal has no information, send download URL
#              for analysis (and future retrieval)

. "$psscriptroot\..\lib\core.ps1"
. "$psscriptroot\..\lib\help.ps1"
. "$psscriptroot\..\lib\getopt.ps1"
. "$psscriptroot\..\lib\manifest.ps1"
. "$psscriptroot\..\lib\buckets.ps1"
. "$psscriptroot\..\lib\json.ps1"

reset_aliases

$opt, $apps, $err = getopt $args 'sa:' @('arch=', 'scan')
if($err) { "scoop virustotal: $err"; exit 1 }
$architecture = ensure_architecture ($opt.a + $opt.arch)

$_ERR_UNSAFE = 2
$_ERR_EXCEPTION = 4
$_ERR_NO_INFO = 8

$exit_code = 0

Function Navigate-ToHash($hash, $app) {
    $hash = $hash.ToLower()
    $result = (new-object net.webclient).downloadstring("https://www.virustotal.com/ui/files/$hash")
    $stats = json_path $result '$.data.attributes.last_analysis_stats'
    $malicious = json_path $stats '$.malicious'
    $suspicious = json_path $stats '$.suspicious'
    $undetected = json_path $stats '$.undetected'
    $unsafe = [int]$malicious + [int]$suspicious
    $see_url = "see https://www.virustotal.com/#/file/$hash/detection"
    if($unsafe -gt 0) {
        write-host -f red "$app`: $unsafe/$undetected, $see_url"
        return $_ERR_UNSAFE
    } else {
        write-host -f green "$app`: $unsafe/$undetected, $see_url"
        return 0
    }
}

Function Start-VirusTotal ($h, $app) {
    if ($h -match "(?<algo>[^:]+):(?<hash>.*)") {
        $hash = $matches["hash"]
        if ($matches["algo"] -match "(md5|sha1|sha256)") {
            return Navigate-ToHash $hash $app
        }
        else {
            write-host -f darkred "$app uses $($matches['algo']) hash and VirusTotal only supports md5, sha1 or sha256"
            return $_ERR_NO_INFO
        }
    }
    else {
        return Navigate-ToHash $h $app
    }
}

Function Get-RedirectedUrl {
    # Follow up to one level of HTTP redirection
    #
    # Copied from http://www.powershellmagazine.com/2013/01/29/pstip-retrieve-a-redirected-url/
    # Adapted according to Roy's response (January 23, 2014 at 11:59 am)
    # Adapted to always return an URL
    Param (
        [Parameter(Mandatory=$true)]
        [String]$URL
    )
    $request = [System.Net.WebRequest]::Create($url)
    $request.AllowAutoRedirect=$false
    $response=$request.GetResponse()
    if ($response.StatusCode -eq "Found") {
        $redir = $response.GetResponseHeader("Location")
    }
    else {
        $redir = $URL
    }
    $response.Close()
    return $redir
}

Function SubmitMaybe-ToVirusTotal ($url, $app, $do_scan) {
    if ($do_scan) {
        try {
            # Follow redirections (for e.g. sourceforge URLs) because
            # VirusTotal analyzes only "direct" download links
            $new_redir = $url
            do {
                $orig_redir = $new_redir
                $new_redir = Get-RedirectedUrl $orig_redir
            } while ($orig_redir -ne $new_redir)
            Invoke-RestMethod -Method POST -Uri "https://www.virustotal.com/ui/urls?url=$new_redir" | Out-Null
            $submitted = $True
        } catch [Exception] {
            $submitted = $False
        }
    }
    else {
        $submitted = $False
    }
    if ($submitted) {
        write-host -f darkred "$app`: $url unknown but submitted to VirusTotal"
    }
    else {
        write-host -f darkred "$app`: unknown, download $url & submit to https`://www.virustotal.com/"
    }
}

if(!$apps) {
    my_usage; exit 1
}

$apps | % {
    $app = $_
    $manifest, $bucket = find_manifest $app
    if(!$manifest) {
        $exit_code = $exit_code -bor $_ERR_NO_INFO
        write-host -f darkred "Could not find manifest for '$app'"
        return
    }

    $hash = hash $manifest $architecture
    if (!$hash) {
        $exit_code = $exit_code -bor $_ERR_NO_INFO
        write-host -f darkred "No hash information for $app"
        return
    }

    $url = url $manifest $architecture

    # Hacky way to see if $hash is an array (i.e. there was a list of
    # hashes in the manifest) or a string (i.e. there was 1! hash in
    # the manifest).
    if ($hash[0].Length -eq 1) {
        # Wrap download URL in array to traverse it in lockstep with
        # the loop over the hash.
        $url = @($url)
    }

    $hash | % { $i = 0 } {
        try {
            $exit_code = $exit_code -bor (Start-VirusTotal $_ $app)
        } catch [Exception] {
            $exit_code = $exit_code -bor $_ERR_EXCEPTION
            if ($_.Exception.Message -like "*(404)*") {
                SubmitMaybe-ToVirusTotal $url[$i] $app ($opt.scan -or $opt.s)
            }
            else {
                write-host -f darkred "$app`: error fetching information`: $($_.Exception.Message)"
            }
        }
        $i = $i + 1
    }
}

exit $exit_code

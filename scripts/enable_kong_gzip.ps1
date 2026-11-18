# Pokreni NAKON "supabase start" — CLI rekreira Kong kontejner bez gzip env varijabli.
# gzip smanjuje REST payload ~5-6x (v3_finansije 2.4MB -> ~430KB), kljucno za Tailscale Funnel put.
$kong = 'supabase_kong_gavra_android'
$old  = 'supabase_kong_gavra_android_orig'
$img  = 'gavra_kong_gzip:local'

if (-not (docker ps -q -f "name=^$kong$")) { Write-Error "$kong ne radi. Prvo 'supabase start'."; exit 1 }

docker commit $kong $img | Out-Null
docker stop $kong | Out-Null
docker rm $kong -f 2>$null | Out-Null   # orig se ne cuva; vrati ga rucno ako treba
docker rm $old  -f 2>$null | Out-Null

docker run -d --name $kong `
  --network supabase_network_gavra_android --network-alias kong --network-alias api.supabase.internal `
  -p 54321:8000 --restart unless-stopped `
  --label com.docker.compose.project=gavra_android --label com.supabase.cli.project=gavra_android `
  -e KONG_NGINX_PROXY_GZIP=on -e KONG_NGINX_PROXY_GZIP_PROXIED=any `
  -e "KONG_NGINX_HTTP_GZIP_TYPES=application/json text/plain text/css application/javascript" `
  -e KONG_NGINX_HTTP_GZIP_MIN_LENGTH=256 -e KONG_NGINX_HTTP_GZIP_VARY=on `
  $img | Out-Null

Start-Sleep -Seconds 8
docker ps --filter "name=^$kong$" --format '{{.Status}}'
Write-Host "Test: curl -H 'Accept-Encoding: gzip' http://127.0.0.1:54321/rest/v1/ -o NUL -w '%{size_download}' -> treba da vrati Content-Encoding: gzip u headerima"

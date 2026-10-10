if WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then
  WowauditGameVersion = "live"
elseif WOW_PROJECT_CAMELOT and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT then
  WowauditGameVersion = "classic_forever"
else
  WowauditGameVersion = "classic"
end

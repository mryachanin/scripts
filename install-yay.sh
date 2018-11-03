# Needs binutils or throws:
#   Cannot find the strip binary required for object file stripping.
cd /tmp
git clone https://aur.archlinux.org/yay.git
cd yay
yes | makepkg -si


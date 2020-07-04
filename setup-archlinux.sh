# make sure all packages are up-to-date
sudo pacman -Syy

# Access the AUR
./install-yay.sh

# Base GUI
sudo pacman -S xf86-video-intel xorg lightdm lightdm-gtk-greeter i3 dmenu xfce4-terminal
sudo systemctl enable lightdm

# audio
sudo pacman -S pulseaudio pulseaudio-alsa pavucontrol

# communication
sudo pacman -S signal-desktop

# data
sudo pacman -S nemo syncthing syncthing-gtk

# dev tools
sudo pacman -S git firefox tree visual-studio-code-bin zsh
## .Net
sudo pacman -S dotnet-runtime dotnet-sdk
## Generate SSH key
ssh-keygen -t rsa -b 8196
## Set shell to zsh
usermod -s /bin/zsh $USER

# document tools
sudo pacman -S libreoffice-fresh

# fonts
sudo pacman -S ttf-dejavu ttf-liberation noto-fonts

# image tools
sudo pacman -S feh

# networking
sudo pacman -S networkmanager network-manager-applet
sudo systemctl enable NetworkManager

# ops tools
sudo pacman -S htop openssh tmux vim

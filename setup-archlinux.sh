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
sudo pacman -S nemo smbclient syncthing syncthing-gtk
sudo yay -S standardnotes-desktop

# dev tools
sudo pacman -S git firefox tree visual-studio-code-bin zsh
## .Net
sudo pacman -S dotnet-runtime dotnet-sdk
## Generate SSH key
ssh-keygen -t rsa -b 8196
## Set shell to zsh
usermod -s /bin/zsh $USER

# document tools
sudo pacman -S evince libreoffice-fresh

# fonts
## Install jp fonts because no shrug no life
sudo pacman -S ttf-dejavu ttf-liberation noto-fonts adobe-source-han-sans-jp-fonts
sudo sed -i 's/#ja_JP.UTF-8/ja_JP.UTF-8/g' /etc/locale.gen
sudo locale-gen

# image tools
sudo pacman -S feh

# media tools
sudo pacman -S vlc

# networking
sudo pacman -S networkmanager network-manager-applet
sudo systemctl enable NetworkManager
sudo systemctl start NetworkManager

# ops tools
sudo pacman -S htop openssh tmux vim

# printer
sudo pacman -S cups cups-pdf
sudo systemctl enable org.cups.cupsd.service
sudo systemctl start org.cups.cupsd.service

# time
sudo pacman -S ntp
sudo systemctl enable ntpd
sudo systemctl start ntpd

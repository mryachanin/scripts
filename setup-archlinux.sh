# make sure all packages are up-to-date
sudo pacman -Syy

# Access the AUR
./install-yay.sh

# base GUI
sudo pacman -S xf86-video-intel xorg lightdm lightdm-gtk-greeter i3 dmenu xfce4-terminal
sudo systemctl enable lightdm

# data
sudo pacman -S nemo syncthing syncthing-gtk

# dev tools
sudo pacman -S git firefox visual-studio-code-bin zsh
ssh-keygen -t rsa -b 8196
usermod -s /bin/zsh $USER

# fonts
sudo pacman -S ttf-dejavu ttf-liberation noto-fonts

# networking
sudo pacman -S networkmanager network-manager-applet
sudo systemctl enable NetworkManager

# ops tools
sudo pacman -S htop openssh tmux vim

# audio
sudo pacman -S pulseaudio pulseaudio-alsa pavucontrol

# image tools
sudo pacman -S feh

#!/bin/bash

# Array of major planets and the ten largest minor planets in our solar system
planets=("Mercury" "Venus" "Earth" "Mars" "Jupiter" "Saturn" "Uranus" "Neptune" "Pluto" "Ceres" "Eris" "Makemake" "Haumea" "Gonggong" "Quaoar" "Varda" "Sedna" "Orcus")

# Generate a random index
random_index=$((RANDOM % ${#planets[@]}))

# Get the random planet
random_planet="${planets[$random_index]}"

# Display the greeting
echo "Hello $random_planet"